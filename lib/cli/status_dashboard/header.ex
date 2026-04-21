defmodule CLI.StatusDashboard.Header do
  @moduledoc """
  Renders the header/hero panel of the status dashboard: agent count,
  throughput, runtime, tokens, cost, project URL, dashboard URL, and
  next refresh line.
  """

  alias CLI.StatusDashboard.Formatters, as: F

  @spec render(map(), number(), map()) :: [String.t() | [String.t()]]
  def render(snapshot, tps, context) do
    %{running: running, agent_totals: agent_totals} = snapshot
    agent_input_tokens = Map.get(agent_totals, :input_tokens, 0)
    agent_output_tokens = Map.get(agent_totals, :output_tokens, 0)
    agent_total_tokens = Map.get(agent_totals, :total_tokens, 0)
    agent_seconds_running = Map.get(agent_totals, :seconds_running, 0)
    agent_cost_usd = Map.get(agent_totals, :cost_usd, 0.0)
    agent_count = length(running)
    max_agents = context.max_agents

    [
      F.colorize("╭─ HORTATOR STATUS", F.ansi_bold()),
      F.colorize("│ Agents: ", F.ansi_bold()) <>
        F.colorize("#{agent_count}", F.ansi_green()) <>
        F.colorize("/", F.ansi_gray()) <>
        F.colorize("#{max_agents}", F.ansi_gray()),
      F.colorize("│ Throughput: ", F.ansi_bold()) <>
        F.colorize("#{format_tps(tps)} tps", F.ansi_cyan()),
      F.colorize("│ Runtime: ", F.ansi_bold()) <>
        F.colorize(F.format_runtime_seconds(agent_seconds_running), F.ansi_magenta()),
      F.colorize("│ Tokens: ", F.ansi_bold()) <>
        F.colorize("in #{F.format_count(agent_input_tokens)}", F.ansi_yellow()) <>
        F.colorize(" | ", F.ansi_gray()) <>
        F.colorize("out #{F.format_count(agent_output_tokens)}", F.ansi_yellow()) <>
        F.colorize(" | ", F.ansi_gray()) <>
        F.colorize("total #{F.format_count(agent_total_tokens)}", F.ansi_yellow()),
      F.colorize("│ Cost: ", F.ansi_bold()) <>
        F.colorize("$#{F.format_cost_usd(agent_cost_usd)}", F.ansi_cyan()),
      rate_limit_header_line(running),
      format_project_link_lines(context),
      format_project_refresh_line(Map.get(snapshot, :polling))
    ]
  end

  @spec render_error(number(), map()) :: [String.t() | [String.t()]]
  def render_error(tps, context) do
    [
      F.colorize("╭─ HORTATOR STATUS", F.ansi_bold()),
      F.colorize("│ Orchestrator snapshot unavailable", F.ansi_red()),
      F.colorize("│ Throughput: ", F.ansi_bold()) <>
        F.colorize("#{format_tps(tps)} tps", F.ansi_cyan()),
      format_project_link_lines(context),
      format_project_refresh_line(nil)
    ]
  end

  # --- internal helpers ---

  defp format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> F.group_thousands()
  end

  defp format_project_link_lines(context) do
    project_part =
      case context.project_slug do
        project_slug when is_binary(project_slug) and project_slug != "" ->
          F.colorize(linear_project_url(project_slug), F.ansi_cyan())

        _ ->
          F.colorize("n/a", F.ansi_gray())
      end

    project_line = F.colorize("│ Project: ", F.ansi_bold()) <> project_part

    case CLI.StatusDashboard.dashboard_url(context.dashboard_host, context.dashboard_port) do
      url when is_binary(url) ->
        [project_line, F.colorize("│ Dashboard: ", F.ansi_bold()) <> F.colorize(url, F.ansi_cyan())]

      _ ->
        [project_line]
    end
  end

  defp format_project_refresh_line(%{checking?: true}) do
    F.colorize("│ Next refresh: ", F.ansi_bold()) <> F.colorize("checking now…", F.ansi_cyan())
  end

  defp format_project_refresh_line(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    due_in_ms = max(due_in_ms, 0)
    seconds = div(due_in_ms + 999, 1000)
    F.colorize("│ Next refresh: ", F.ansi_bold()) <> F.colorize("#{seconds}s", F.ansi_cyan())
  end

  defp format_project_refresh_line(_) do
    F.colorize("│ Next refresh: ", F.ansi_bold()) <> F.colorize("n/a", F.ansi_gray())
  end

  defp linear_project_url(project_slug), do: "https://linear.app/project/#{project_slug}/issues"

  defp rate_limit_header_line(running) when is_list(running) do
    throttled =
      running
      |> Enum.map(&Map.get(&1, :rate_limit_info))
      |> Enum.filter(&(is_map(&1) and rate_limit_status(&1) not in [nil, "allowed"]))

    case throttled do
      [] ->
        []

      infos ->
        statuses =
          infos
          |> Enum.map(&rate_limit_status/1)
          |> Enum.uniq()
          |> Enum.join(", ")

        earliest_reset =
          infos
          |> Enum.map(&rate_limit_resets_at/1)
          |> Enum.filter(&is_integer/1)
          |> Enum.min(fn -> nil end)

        reset_suffix =
          case earliest_reset do
            nil -> ""
            ts -> " · resets #{format_reset_time(ts)}"
          end

        F.colorize("│ Rate limit: ", F.ansi_bold()) <>
          F.colorize("#{statuses} · #{length(infos)} session(s)#{reset_suffix}", F.ansi_red())
    end
  end

  defp rate_limit_status(info) when is_map(info),
    do: Map.get(info, "status") || Map.get(info, :status)

  defp rate_limit_resets_at(info) when is_map(info) do
    case Map.get(info, "resetsAt") || Map.get(info, :resetsAt) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp format_reset_time(unix_seconds) when is_integer(unix_seconds) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, dt} ->
        dt
        |> DateTime.shift_zone!("Etc/UTC")
        |> Calendar.strftime("%H:%M UTC")

      _ ->
        "?"
    end
  end
end
