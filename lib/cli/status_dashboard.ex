defmodule CLI.StatusDashboard do
  @moduledoc """
  Pure rendering for the terminal status dashboard.

  `format_snapshot_content/4` takes the orchestrator snapshot plus a context
  map (project slug, dashboard URL inputs, agent caps, terminal width) and
  returns the fully-formatted ANSI string that `Core.StatusDashboard` writes
  to stdout. Everything here is side-effect free — no Application env reads,
  no process calls, no I/O. Core composes Config reads and hands the values
  in.
  """

  alias CLI.StatusDashboard.AgentMessage
  alias CLI.StatusDashboard.AgentTable
  alias CLI.StatusDashboard.Formatters, as: F
  alias CLI.StatusDashboard.Header
  alias CLI.StatusDashboard.RetryQueue

  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  @throughput_graph_columns 24
  @throughput_graph_window_ms 10 * 60 * 1000
  @throughput_window_ms 5_000

  @type context :: %{
          required(:max_agents) => non_neg_integer(),
          required(:dashboard_host) => String.t(),
          required(:dashboard_port) => non_neg_integer() | nil,
          required(:project_slug) => String.t() | nil
        }

  @spec format_snapshot_content(term(), number(), context(), integer() | nil) :: String.t()
  def format_snapshot_content(snapshot_data, tps, context, terminal_columns_override \\ nil)

  # credo:disable-for-next-line
  def format_snapshot_content({:ok, snapshot} = snapshot_data, tps, context, terminal_columns_override) do
    _ = snapshot_data
    %{running: running, retrying: retrying} = snapshot
    running_to_backoff_spacer = if(running == [], do: [], else: ["│"])

    (Header.render(snapshot, tps, context) ++
       AgentTable.render(running, terminal_columns_override) ++
       running_to_backoff_spacer ++
       RetryQueue.render(retrying) ++
       [closing_border()])
    |> List.flatten()
    |> Enum.join("\n")
  end

  def format_snapshot_content(:error, tps, context, _terminal_columns_override) do
    (Header.render_error(tps, context) ++ [closing_border()])
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec render_offline_status_content() :: String.t()
  def render_offline_status_content do
    [
      F.colorize("╭─ HORTATOR STATUS", F.ansi_bold()),
      F.colorize("│ app_status=offline", F.ansi_red()),
      closing_border()
    ]
    |> Enum.join("\n")
  end

  @spec render_to_terminal(String.t()) :: :ok
  def render_to_terminal(content) do
    IO.write([
      IO.ANSI.home(),
      IO.ANSI.clear(),
      content,
      "\n"
    ])

    :ok
  end

  @doc """
  Render an agent event message into a short human-readable string for the
  dashboard. Delegates to `CLI.StatusDashboard.AgentMessage`.
  """
  @spec humanize_agent_message(term()) :: String.t()
  defdelegate humanize_agent_message(message), to: AgentMessage

  @doc false
  @spec rolling_tps([{integer(), integer()}], integer(), integer()) :: float()
  def rolling_tps(samples, now_ms, current_tokens) do
    samples = [{now_ms, current_tokens} | samples]
    samples = prune_samples(samples, now_ms)

    case samples do
      [] ->
        0.0

      [_one] ->
        0.0

      _ ->
        first = List.last(samples)
        {start_ms, start_tokens} = first
        elapsed_ms = now_ms - start_ms
        delta_tokens = max(0, current_tokens - start_tokens)

        if elapsed_ms <= 0 do
          0.0
        else
          delta_tokens / (elapsed_ms / 1000.0)
        end
    end
  end

  @doc false
  @spec throttled_tps(
          integer() | nil,
          float() | nil,
          integer(),
          [{integer(), integer()}],
          integer()
        ) ::
          {integer(), float()}
  def throttled_tps(last_second, last_value, now_ms, token_samples, current_tokens) do
    second = div(now_ms, 1000)

    if is_integer(last_second) and last_second == second and is_number(last_value) do
      {second, last_value}
    else
      {second, rolling_tps(token_samples, now_ms, current_tokens)}
    end
  end

  @doc false
  @spec update_token_samples([{integer(), integer()}], integer(), integer()) :: [{integer(), integer()}]
  def update_token_samples(samples, now_ms, total_tokens) do
    prune_graph_samples([{now_ms, total_tokens} | samples], now_ms)
  end

  @doc false
  @spec prune_samples([{integer(), integer()}], integer()) :: [{integer(), integer()}]
  def prune_samples(samples, now_ms) do
    min_timestamp = now_ms - @throughput_window_ms
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  @doc """
  Format a running-agent entry as a single dashboard row. Used from
  `format_snapshot_content/4` and directly from tests that exercise a
  single-row layout.
  """
  @spec format_running_summary(map(), integer() | nil) :: String.t()
  defdelegate format_running_summary(running_entry, terminal_columns \\ nil), to: AgentTable

  @doc """
  Build the full dashboard URL for a host/port pair, applying loopback and
  IPv6-bracketing normalization. Returns nil when `port` is nil or 0.
  """
  @spec dashboard_url(String.t(), non_neg_integer() | nil) :: String.t() | nil
  def dashboard_url(_host, nil), do: nil

  def dashboard_url(host, port) when is_integer(port) and port > 0 do
    "http://#{dashboard_url_host(host)}:#{port}/"
  end

  def dashboard_url(_host, _port), do: nil

  @doc """
  Render a sparkline string of tokens-per-second over the throughput graph
  window (10 minutes at 24 columns).
  """
  @spec tps_graph([{integer(), integer()}], integer(), integer()) :: String.t()
  def tps_graph(samples, now_ms, current_tokens) do
    bucket_ms = div(@throughput_graph_window_ms, @throughput_graph_columns)
    active_bucket_start = div(now_ms, bucket_ms) * bucket_ms
    graph_window_start = active_bucket_start - (@throughput_graph_columns - 1) * bucket_ms

    rates =
      [{now_ms, current_tokens} | samples]
      |> prune_graph_samples(now_ms)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{start_ms, start_tokens}, {end_ms, end_tokens}] ->
        elapsed_ms = end_ms - start_ms
        delta_tokens = max(0, end_tokens - start_tokens)
        tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
        {end_ms, tps}
      end)

    bucketed_tps =
      0..(@throughput_graph_columns - 1)
      |> Enum.map(fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @throughput_graph_columns - 1

        values =
          rates
          |> Enum.filter(fn {timestamp, _tps} ->
            in_bucket?(timestamp, bucket_start, bucket_end, last_bucket?)
          end)
          |> Enum.map(fn {_timestamp, tps} -> tps end)

        if values == [] do
          0.0
        else
          Enum.sum(values) / length(values)
        end
      end)

    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    bucketed_tps
    |> Enum.map_join(fn value ->
      index =
        if max_tps <= 0 do
          0
        else
          round(value / max_tps * (length(@sparkline_blocks) - 1))
        end

      Enum.at(@sparkline_blocks, index, "▁")
    end)
  end

  @doc """
  Format an integer or numeric TPS value with thousands separators.
  """
  @spec format_tps(number()) :: String.t()
  def format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> F.group_thousands()
  end

  @doc """
  Format a DateTime as a second-precision UTC string (the dashboard header
  timestamp).
  """
  @spec format_timestamp(DateTime.t()) :: String.t()
  def format_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  ## --- internal helpers --------------------------------------------------

  defp prune_graph_samples(samples, now_ms) do
    min_timestamp = now_ms - max(@throughput_window_ms, @throughput_graph_window_ms)
    Enum.filter(samples, fn {timestamp, _} -> timestamp >= min_timestamp end)
  end

  defp dashboard_url_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"

  defp dashboard_url_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    cond do
      trimmed_host in ["0.0.0.0", "::", "[::]", ""] ->
        "127.0.0.1"

      String.starts_with?(trimmed_host, "[") and String.ends_with?(trimmed_host, "]") ->
        trimmed_host

      String.contains?(trimmed_host, ":") ->
        "[#{trimmed_host}]"

      true ->
        trimmed_host
    end
  end

  defp in_bucket?(timestamp, bucket_start, bucket_end, true),
    do: timestamp >= bucket_start and timestamp <= bucket_end

  defp in_bucket?(timestamp, bucket_start, bucket_end, false),
    do: timestamp >= bucket_start and timestamp < bucket_end

  defp closing_border, do: "╰─"
end
