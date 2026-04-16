defmodule Agents.Claude.Session do
  @moduledoc """
  Long-running client for the Claude Code stream-json subprocess.

  Hortator spawns one `claude` process per logical session and feeds it
  line-delimited JSON user messages on stdin, reading line-delimited JSON
  events from stdout until each `result` event arrives.

  Events are emitted via the `:on_message` callback in a shape compatible
  with the orchestrator's `:agent_worker_update` handler:

      %{
        event: :session_started | :notification | :turn_completed |
               :turn_failed | :startup_failed,
        timestamp: DateTime.utc_now(),
        session_id: <uuid>,           # set once known
        payload: parsed_event_map,    # decoded JSON event from claude
        raw: raw_line,                # original stdout line
        usage: extracted_usage_or_nil,
        metadata...                   # port pid, worker_host, etc.
      }

  Subprocess launch + argv and the stream-json receive loop live in
  `Agents.Claude.Session.CommandBuilder` and
  `Agents.Claude.Session.StreamParser`.
  """

  require Logger

  alias Agents.Claude.Session.CommandBuilder
  alias Agents.Claude.Session.StreamParser

  @type claude_settings :: %{
          optional(:command) => String.t() | nil,
          optional(:permission_mode) => String.t(),
          optional(:model) => String.t(),
          optional(:effort) => String.t() | nil,
          optional(:mcp_config_path) => String.t() | nil,
          required(:turn_timeout_ms) => non_neg_integer()
        }

  @type session :: %{
          port: port(),
          session_id: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil,
          claude: claude_settings(),
          metadata: map(),
          turn_count: non_neg_integer()
        }

  @type on_message :: (map() -> any())

  @doc """
  Start a Claude Code session in the given workspace.

  `opts` must include:
    * `:claude` — a `claude_settings()` map (command, permission_mode, model,
      effort, mcp_config_path, turn_timeout_ms).

  `opts` may include:
    * `:worker_host` — SSH host for remote sessions. Default: nil (local).
    * `:workspace_root` — required for local sessions. Used to validate the
      workspace path stays under the configured root. Ignored when
      `:worker_host` is set (remote paths are validated separately).
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    claude = Keyword.fetch!(opts, :claude)
    workspace_root = Keyword.get(opts, :workspace_root)

    with {:ok, expanded_workspace} <-
           CommandBuilder.validate_workspace_cwd(workspace, worker_host, workspace_root),
         {:ok, port} <- CommandBuilder.start_port(expanded_workspace, worker_host, claude) do
      base_metadata = CommandBuilder.port_metadata(port, worker_host)

      # NOTE: Claude Code's `--print --input-format stream-json` mode does not
      # emit any events on stdout until it receives the first user message on
      # stdin. We used to wait for a `system` init event here, which deadlocked
      # forever (well, until read_timeout_ms). The session_id is captured
      # lazily by `run_turn/4` from the first system init event that arrives
      # in the receive loop after the first user message is written.
      {:ok,
       %{
         port: port,
         session_id: nil,
         workspace: expanded_workspace,
         worker_host: worker_host,
         claude: claude,
         metadata: base_metadata,
         turn_count: 0
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          session_id: existing_session_id,
          claude: %{turn_timeout_ms: turn_timeout_ms},
          metadata: metadata,
          turn_count: turn_count
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &StreamParser.default_on_message/1)
    turn_id = turn_count + 1

    case send_user_message(port, prompt) do
      :ok ->
        initial_state = %{session_id: existing_session_id, session_started_emitted?: false}

        port
        |> await_turn_completion(on_message, metadata, initial_state, turn_id, turn_timeout_ms)
        |> finalize_run_turn(session, on_message, turn_id, issue)

      {:error, reason} ->
        Logger.error("Claude session failed to send user message for #{issue_context(issue)} session_id=#{existing_session_id || "n/a"}: #{inspect(reason)}")

        StreamParser.emit_message(
          on_message,
          :startup_failed,
          %{reason: reason, session_id: existing_session_id},
          metadata
        )

        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port), do: CommandBuilder.stop_port(port)

  ## --- internal helpers --------------------------------------------------

  defp finalize_run_turn({:ok, result_payload, final_state}, session, _on_message, turn_id, issue) do
    session_id = final_state.session_id

    Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id || "n/a"} turn=#{turn_id}")

    updated_session = %{
      session
      | turn_count: turn_id,
        session_id: session_id,
        metadata: maybe_update_session_metadata(session.metadata, session_id)
    }

    {:ok,
     %{
       result: result_payload,
       session_id: session_id,
       turn_id: turn_id,
       session: updated_session
     }}
  end

  defp finalize_run_turn({:error, reason, final_state}, session, on_message, turn_id, issue) do
    session_id = final_state.session_id

    Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id || "n/a"} turn=#{turn_id}: #{inspect(reason)}")

    StreamParser.emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: session_id, turn_id: turn_id, reason: reason},
      %{}
    )

    # Even on error, advance turn_count and capture any session_id we learned
    # so a follow-up retry doesn't start from a stale state.
    _updated_session = %{
      session
      | turn_count: turn_id,
        session_id: session_id,
        metadata: maybe_update_session_metadata(session.metadata, session_id)
    }

    {:error, reason}
  end

  defp maybe_update_session_metadata(metadata, nil), do: metadata

  defp maybe_update_session_metadata(metadata, session_id),
    do: Map.put(metadata, :session_id, session_id)

  defp send_user_message(port, prompt) when is_binary(prompt) do
    payload = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => prompt}
    }

    line = Jason.encode!(payload) <> "\n"

    try do
      true = Port.command(port, line)
      :ok
    rescue
      ArgumentError -> {:error, :port_closed}
    end
  end

  defp await_turn_completion(port, on_message, metadata, initial_state, turn_id, timeout_ms) do
    StreamParser.receive_event_loop(
      port,
      timeout_ms,
      "",
      initial_state,
      &StreamParser.handle_turn_event(&1, &2, &3, on_message, metadata, turn_id)
    )
  end

  defp issue_context(%{id: issue_id, identifier: identifier}),
    do: "issue_id=#{issue_id} issue_identifier=#{identifier}"

  defp issue_context(_), do: "issue_id=unknown issue_identifier=unknown"
end
