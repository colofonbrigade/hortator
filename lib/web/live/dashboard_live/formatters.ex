defmodule Web.DashboardLive.Formatters do
  @moduledoc """
  Pure formatting and presentational helpers for the observability dashboard.
  """

  @spec completed_runtime_seconds(map()) :: number()
  def completed_runtime_seconds(payload) do
    payload.agent_totals.seconds_running || 0
  end

  @spec total_runtime_seconds(map(), DateTime.t()) :: number()
  def total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  @spec format_runtime_and_turns(DateTime.t() | String.t() | nil, integer() | nil, DateTime.t()) :: String.t()
  def format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  def format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  @spec format_runtime_seconds(number()) :: String.t()
  def format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  @spec runtime_seconds_from_started_at(DateTime.t() | String.t() | nil, DateTime.t()) :: number()
  def runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  def runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  def runtime_seconds_from_started_at(_started_at, _now), do: 0

  @spec format_int(integer() | any()) :: String.t()
  def format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  def format_int(_value), do: "n/a"

  @spec state_badge_class(atom() | String.t()) :: String.t()
  def state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  @spec rate_limit_badge_label(map() | any()) :: String.t() | nil
  def rate_limit_badge_label(info) when is_map(info) do
    case Map.get(info, "status") || Map.get(info, :status) do
      status when status in [nil, "allowed", :allowed] -> nil
      status -> to_string(status)
    end
  end

  def rate_limit_badge_label(_info), do: nil

  @spec rate_limit_badge_title(map() | any()) :: String.t()
  def rate_limit_badge_title(info) when is_map(info) do
    type = Map.get(info, "rateLimitType") || Map.get(info, :rateLimitType) || "unknown"
    resets = Map.get(info, "resetsAt") || Map.get(info, :resetsAt)

    "type: #{type}" <>
      case resets do
        n when is_integer(n) -> " · resets #{format_reset_iso(n)}"
        _ -> ""
      end
  end

  def rate_limit_badge_title(_info), do: ""

  @spec rate_limit_summary_line(list() | any()) :: String.t() | nil
  def rate_limit_summary_line(running) when is_list(running) do
    throttled =
      running
      |> Enum.map(& &1.rate_limit_info)
      |> Enum.filter(&(is_map(&1) and rate_limit_badge_label(&1)))

    case throttled do
      [] ->
        nil

      infos ->
        statuses =
          infos
          |> Enum.map(&rate_limit_badge_label/1)
          |> Enum.uniq()
          |> Enum.join(", ")

        "Rate limit: #{statuses} — #{length(infos)} session(s) affected"
    end
  end

  def rate_limit_summary_line(_running), do: nil

  @spec format_reset_iso(integer()) :: String.t()
  def format_reset_iso(unix_seconds) when is_integer(unix_seconds) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M UTC")
      _ -> "?"
    end
  end
end
