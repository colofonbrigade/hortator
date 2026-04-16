defmodule Web.ObservabilityApiControllerTest do
  # Runs against the already-running Web.Endpoint from Hortator.Application.
  # Orchestrator + snapshot timeout are injected per-test via Process.put/2 —
  # Utils.Runtime.get/2 walks the process tree so values set in the test
  # process reach the controller without mutating Application env.
  use Web.ConnCase, async: false

  alias Core.Config

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:hortator, :endpoint_orchestrator)
      Application.delete_env(:hortator, :endpoint_snapshot_timeout_ms)
    end)

    :ok
  end

  test "api preserves state, issue, and refresh responses", %{conn: conn} do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    inject_orchestrator(orchestrator_name, 50)

    state_payload = json_response(get(conn, "/api/v1/state"), 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "cost_usd" => 0.0,
                 "rate_limit_info" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "agent_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             }
           }

    issue_payload = json_response(get(conn, "/api/v1/MT-HTTP"), 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "cost_usd" => 0.0,
               "rate_limit_info" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"agent_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    retry_payload = json_response(get(conn, "/api/v1/MT-RETRY"), 200)
    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} = retry_payload

    assert json_response(get(conn, "/api/v1/MT-MISSING"), 404) ==
             %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}

    refresh_payload = json_response(post(conn, "/api/v1/refresh", %{}), 202)
    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} = refresh_payload
  end

  test "api preserves 405, 404, and unavailable behavior", %{conn: conn} do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    inject_orchestrator(unavailable_orchestrator, 5)

    assert json_response(post(conn, "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(conn, "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(conn, "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    state_payload = json_response(get(conn, "/api/v1/state"), 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
           }

    assert json_response(post(conn, "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "api preserves snapshot timeout behavior", %{conn: conn} do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    inject_orchestrator(timeout_orchestrator, 1)

    payload = json_response(get(conn, "/api/v1/state"), 200)

    assert payload == %{
             "generated_at" => payload["generated_at"],
             "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
           }
  end

  defp inject_orchestrator(name, timeout_ms) do
    # Application env is read by both the test process and any Phoenix-spawned
    # processes handling the conn; Process.put covers the ancestry walk in
    # Utils.Runtime.get.
    Application.put_env(:hortator, :endpoint_orchestrator, name)
    Application.put_env(:hortator, :endpoint_snapshot_timeout_ms, timeout_ms)
    Process.put(:endpoint_orchestrator, name)
    Process.put(:endpoint_snapshot_timeout_ms, timeout_ms)
    :ok
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          agent_pid: nil,
          last_agent_message: "rendered",
          last_agent_timestamp: nil,
          last_agent_event: :notification,
          agent_input_tokens: 4,
          agent_output_tokens: 8,
          agent_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      agent_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5}
    }
  end
end
