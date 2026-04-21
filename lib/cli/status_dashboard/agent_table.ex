defmodule CLI.StatusDashboard.AgentTable do
  @moduledoc """
  Renders the "Running" agents table section of the status dashboard:
  column headers, per-agent rows, and the empty-state message.
  """

  alias CLI.StatusDashboard.AgentMessage
  alias CLI.StatusDashboard.Formatters, as: F

  @running_age_width 12
  @running_event_min_width 12
  @running_event_default_width 44
  @running_id_width 8
  @running_pid_width 8
  @running_row_chrome_width 10
  @running_session_width 14
  @running_stage_width 14
  @running_tokens_width 10
  @default_terminal_columns 115

  @spec render(list(), integer() | nil) :: [String.t()]
  def render(running, terminal_columns_override) do
    event_width = running_event_width(terminal_columns_override)

    [
      F.colorize("├─ Running", F.ansi_bold()),
      "│",
      table_header_row(event_width),
      table_separator_row(event_width)
    ] ++ format_running_rows(running, event_width)
  end

  @doc """
  Format a single running-agent entry as a dashboard row.
  """
  @spec format_running_summary(map(), integer() | nil) :: String.t()
  def format_running_summary(running_entry, terminal_columns) do
    format_running_row(running_entry, running_event_width(terminal_columns))
  end

  @doc """
  Compute the event column width for a given terminal width.
  """
  @spec running_event_width(integer() | nil) :: non_neg_integer()
  def running_event_width(terminal_columns) do
    terminal_columns = terminal_columns || terminal_columns_detect()

    max(
      @running_event_min_width,
      terminal_columns - fixed_running_width() - @running_row_chrome_width
    )
  end

  # --- internal helpers ---

  defp format_running_rows(running, event_width) do
    if running == [] do
      [
        "│  " <> F.colorize("No active agents", F.ansi_gray()),
        "│"
      ]
    else
      running
      |> Enum.sort_by(& &1.identifier)
      |> Enum.map(&format_running_row(&1, event_width))
    end
  end

  # credo:disable-for-next-line
  defp format_running_row(running_entry, event_width) do
    issue = F.format_cell(running_entry.identifier || "unknown", @running_id_width)
    state = running_entry.state || "unknown"
    state_display = F.format_cell(to_string(state), @running_stage_width)

    session =
      running_entry.session_id |> compact_session_id() |> F.format_cell(@running_session_width)

    pid = F.format_cell(running_entry.agent_pid || "n/a", @running_pid_width)
    total_tokens = running_entry.agent_total_tokens || 0
    runtime_seconds = running_entry.runtime_seconds || 0
    turn_count = Map.get(running_entry, :turn_count, 0)
    age = F.format_cell(format_runtime_and_turns(runtime_seconds, turn_count), @running_age_width)
    event = running_entry.last_agent_event || "none"

    event_label =
      F.format_cell(AgentMessage.humanize_agent_message(running_entry.last_agent_message), event_width)

    tokens = F.format_count(total_tokens) |> F.format_cell(@running_tokens_width, :right)

    status_color =
      case event do
        :none -> F.ansi_red()
        :startup_failed -> F.ansi_red()
        :turn_failed -> F.ansi_red()
        :turn_ended_with_error -> F.ansi_red()
        :turn_completed -> F.ansi_magenta()
        :session_started -> F.ansi_green()
        _ -> F.ansi_blue()
      end

    [
      "│ ",
      status_dot(status_color),
      " ",
      F.colorize(issue, F.ansi_cyan()),
      " ",
      F.colorize(state_display, status_color),
      " ",
      F.colorize(pid, F.ansi_yellow()),
      " ",
      F.colorize(age, F.ansi_magenta()),
      " ",
      F.colorize(tokens, F.ansi_yellow()),
      " ",
      F.colorize(session, F.ansi_cyan()),
      " ",
      F.colorize(event_label, status_color),
      rate_limit_badge(running_entry)
    ]
    |> Enum.join("")
  end

  defp rate_limit_badge(running_entry) do
    case Map.get(running_entry, :rate_limit_info) do
      %{} = info ->
        status = Map.get(info, "status") || Map.get(info, :status)

        if status in [nil, "allowed", :allowed] do
          ""
        else
          " " <> F.colorize("[#{status}]", F.ansi_red())
        end

      _ ->
        ""
    end
  end

  defp table_header_row(event_width) do
    header =
      [
        F.format_cell("ID", @running_id_width),
        F.format_cell("STAGE", @running_stage_width),
        F.format_cell("PID", @running_pid_width),
        F.format_cell("AGE / TURN", @running_age_width),
        F.format_cell("TOKENS", @running_tokens_width),
        F.format_cell("SESSION", @running_session_width),
        F.format_cell("EVENT", event_width)
      ]
      |> Enum.join(" ")

    "│   " <> F.colorize(header, F.ansi_gray())
  end

  defp table_separator_row(event_width) do
    separator_width =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width +
        event_width + 6

    "│   " <> F.colorize(String.duplicate("─", separator_width), F.ansi_gray())
  end

  defp format_runtime_and_turns(seconds, turn_count)
       when is_integer(turn_count) and turn_count > 0 do
    "#{F.format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_runtime_and_turns(seconds, _turn_count), do: F.format_runtime_seconds(seconds)

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end

  defp fixed_running_width do
    @running_id_width +
      @running_stage_width +
      @running_pid_width +
      @running_age_width +
      @running_tokens_width +
      @running_session_width
  end

  defp terminal_columns_detect do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 ->
        columns

      _ ->
        terminal_columns_from_env()
    end
  end

  defp terminal_columns_from_env do
    case System.get_env("COLUMNS") do
      nil ->
        fixed_running_width() + @running_row_chrome_width + @running_event_default_width

      value ->
        case Integer.parse(String.trim(value)) do
          {columns, ""} when columns > 0 -> columns
          _ -> @default_terminal_columns
        end
    end
  end

  defp status_dot(color_code) do
    F.colorize("●", color_code)
  end
end
