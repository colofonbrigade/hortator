defmodule Agents.Claude.Session.StreamParser do
  @moduledoc """
  Line-delimited stream-json receive loop for the `claude` subprocess.

  The session GenServer hands `receive_event_loop/5` a port, a starting
  `state` (session_id, session_started_emitted?), and a handler of arity 3.
  The loop accumulates partial lines, decodes each completed JSON object,
  and dispatches to `handle_turn_event/6` which emits `:session_started`,
  `:turn_completed`, `:turn_failed`, or `:notification` messages via the
  caller-supplied `on_message` callback.

  All functions here are pure with respect to Hortator state: they read
  from and return the opaque handler state plus emit events through the
  caller's `on_message/1` function.
  """

  require Logger

  @max_stream_log_bytes 1_000

  @type handler_state :: %{session_id: String.t() | nil, session_started_emitted?: boolean()}
  @type handler_result ::
          {:continue, handler_state()}
          | {:ok, map(), handler_state()}
          | {:error, term(), handler_state()}

  @doc """
  Threads `state` through the receive loop. The handler receives
  `(payload, raw_line, state)` and returns one of:

    * `{:continue, new_state}` — more events expected
    * `{:ok, result, new_state}` — terminal success
    * `{:error, reason, new_state}` — terminal error

  Terminal results carry the final state so callers can capture data
  accumulated during the receive loop (e.g. session_id from a `system`
  init event).
  """
  @spec receive_event_loop(
          port(),
          non_neg_integer(),
          String.t(),
          handler_state(),
          (map(), String.t(), handler_state() -> handler_result())
        ) :: {:ok, map(), handler_state()} | {:error, term(), handler_state()}
  def receive_event_loop(port, timeout_ms, pending_line, state, handler) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        process_line(port, timeout_ms, complete_line, state, handler)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_event_loop(port, timeout_ms, pending_line <> to_string(chunk), state, handler)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}, state}
    after
      timeout_ms ->
        {:error, :turn_timeout, state}
    end
  end

  @doc """
  Dispatch a decoded stream-json payload to the appropriate emission path.
  Returns `{:continue, state}` for notifications, `{:ok, payload, state}`
  on `result` success, or `{:error, reason, state}` on `result is_error`.
  """
  @spec handle_turn_event(map(), String.t(), handler_state(), function(), map(), integer()) ::
          handler_result()

  # Result event — terminal. Returns {:ok, payload, state} on success or
  # {:error, reason, state} on a Claude-side error.
  def handle_turn_event(
        %{"type" => "result"} = payload,
        raw,
        state,
        on_message,
        metadata,
        turn_id
      ) do
    is_error = Map.get(payload, "is_error") == true
    state = update_session_id(state, payload)

    event_metadata =
      metadata
      |> put_session_id(state.session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    if is_error do
      emit_message(
        on_message,
        :turn_failed,
        %{payload: payload, raw: raw, details: payload},
        event_metadata
      )

      {:error, {:turn_failed, result_error_reason(payload)}, state}
    else
      emit_message(
        on_message,
        :turn_completed,
        %{payload: payload, raw: raw, details: payload},
        event_metadata
      )

      {:ok, payload, state}
    end
  end

  # System init event — captures session_id (lazily, only once per session)
  # and emits the :session_started boundary event before the receive loop
  # continues into the assistant/result events.
  def handle_turn_event(
        %{"type" => "system", "subtype" => "init"} = payload,
        raw,
        state,
        on_message,
        metadata,
        turn_id
      ) do
    state = update_session_id(state, payload)

    state =
      if state.session_id && not state.session_started_emitted? do
        emit_message(
          on_message,
          :session_started,
          %{session_id: state.session_id, turn_id: turn_id},
          put_session_id(metadata, state.session_id)
        )

        %{state | session_started_emitted?: true}
      else
        state
      end

    event_metadata =
      metadata
      |> put_session_id(state.session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    emit_message(on_message, :notification, %{payload: payload, raw: raw}, event_metadata)

    {:continue, state}
  end

  # Generic notification (assistant/user/rate_limit_event/etc.).
  def handle_turn_event(payload, raw, state, on_message, metadata, turn_id) do
    state = update_session_id(state, payload)

    event_metadata =
      metadata
      |> put_session_id(state.session_id)
      |> Map.put(:turn_id, turn_id)
      |> maybe_put_usage(payload)

    emit_message(on_message, :notification, %{payload: payload, raw: raw}, event_metadata)

    {:continue, state}
  end

  @spec emit_message(function(), atom(), map(), map()) :: any()
  def emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  @spec default_on_message(map()) :: :ok
  def default_on_message(_message), do: :ok

  @spec put_session_id(map(), String.t() | nil) :: map()
  def put_session_id(metadata, nil), do: metadata
  def put_session_id(metadata, session_id), do: Map.put(metadata, :session_id, session_id)

  defp process_line(port, timeout_ms, line, state, handler) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        case handler.(payload, line, state) do
          {:ok, result, new_state} -> {:ok, result, new_state}
          {:error, reason, new_state} -> {:error, reason, new_state}
          {:continue, new_state} -> receive_event_loop(port, timeout_ms, "", new_state, handler)
        end

      {:ok, _other} ->
        log_non_protocol_line(line, "non-map JSON")
        receive_event_loop(port, timeout_ms, "", state, handler)

      {:error, _reason} ->
        log_non_protocol_line(line, "non-JSON output")
        receive_event_loop(port, timeout_ms, "", state, handler)
    end
  end

  defp update_session_id(state, %{"session_id" => session_id}) when is_binary(session_id) do
    %{state | session_id: session_id}
  end

  defp update_session_id(state, _payload), do: state

  defp maybe_put_usage(metadata, payload) when is_map(payload) do
    case extract_usage(payload) do
      usage when is_map(usage) -> Map.put(metadata, :usage, usage)
      _ -> metadata
    end
  end

  defp maybe_put_usage(metadata, _payload), do: metadata

  # Claude Code emits `usage` at the top level of `result` events and nested
  # inside `message` for `assistant` events.
  defp extract_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp extract_usage(%{"message" => %{"usage" => usage}}) when is_map(usage), do: usage
  defp extract_usage(_), do: nil

  defp result_error_reason(%{"result" => result}) when is_binary(result), do: result
  defp result_error_reason(%{"subtype" => subtype}) when is_binary(subtype), do: subtype
  defp result_error_reason(payload), do: payload

  defp log_non_protocol_line(data, label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude #{label}: #{text}")
      else
        Logger.debug("Claude #{label}: #{text}")
      end
    end
  end
end
