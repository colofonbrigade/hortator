defmodule CLI.StatusDashboard.RetryQueue do
  @moduledoc """
  Renders the "Backoff queue" section of the status dashboard:
  retry entry rows and the empty-state message.
  """

  alias CLI.StatusDashboard.Formatters, as: F

  @spec render(list()) :: [String.t()]
  def render(retrying) do
    [F.colorize("├─ Backoff queue", F.ansi_bold()), "│"] ++ format_retry_rows(retrying)
  end

  # --- internal helpers ---

  defp format_retry_rows(retrying) do
    if retrying == [] do
      ["│  " <> F.colorize("No queued retries", F.ansi_gray())]
    else
      retrying
      |> Enum.sort_by(& &1.due_in_ms)
      |> Enum.map_join(", ", &format_retry_summary/1)
      |> String.split(", ")
    end
  end

  defp format_retry_summary(retry_entry) do
    issue_id = retry_entry.issue_id || "unknown"
    identifier = retry_entry.identifier || issue_id
    attempt = retry_entry.attempt || 0
    due_in_ms = retry_entry.due_in_ms || 0
    error = format_retry_error(retry_entry.error)

    "│  #{F.colorize("↻", F.ansi_orange())} " <>
      F.colorize("#{identifier}", F.ansi_red()) <>
      " " <>
      F.colorize("attempt=#{attempt}", F.ansi_yellow()) <>
      F.colorize(" in ", F.ansi_dim()) <>
      F.colorize(next_in_words(due_in_ms), F.ansi_cyan()) <>
      error
  end

  defp next_in_words(due_in_ms) when is_integer(due_in_ms) do
    secs = div(due_in_ms, 1000)
    millis = rem(due_in_ms, 1000)
    "#{secs}.#{String.pad_leading(to_string(millis), 3, "0")}s"
  end

  defp next_in_words(_), do: "n/a"

  defp format_retry_error(error) when is_binary(error) do
    sanitized =
      error
      |> String.replace("\\r\\n", " ")
      |> String.replace("\\r", " ")
      |> String.replace("\\n", " ")
      |> String.replace("\r\n", " ")
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if sanitized == "" do
      ""
    else
      " " <> F.colorize("error=#{F.truncate(sanitized, 96)}", F.ansi_dim())
    end
  end

  defp format_retry_error(_), do: ""
end
