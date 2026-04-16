defmodule Web.DashboardLiveTest do
  # Runs against the already-running Web.Endpoint from Hortator.Application.
  # Orchestrator injection mirrors Web.ObservabilityApiControllerTest.
  use Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Core.StatusDashboard

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

  test "dashboard renders with the shell, dashboard.css link, and snapshot data", %{conn: conn} do
    orchestrator_name = Module.concat(__MODULE__, :ShellOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    inject_orchestrator(orchestrator_name, 50)

    html = html_response(get(conn, "/"), 200)
    assert html =~ "/assets/dashboard.css"
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"
  end

  test "liveview renders and refreshes over pubsub", %{conn: conn} do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    inject_orchestrator(orchestrator_name, 50)

    {:ok, view, html} = live(conn, "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Agent update"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_agent_event: :notification,
          last_agent_message: %{
            event: :notification,
            message: %{
              "type" => "assistant",
              "message" => %{
                "content" => [%{"type" => "text", "text" => "structured update"}]
              }
            }
          },
          last_agent_timestamp: DateTime.utc_now(),
          agent_input_tokens: 10,
          agent_output_tokens: 12,
          agent_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "assistant: structured update"
    end)
  end

  test "liveview renders an unavailable state without crashing", %{conn: conn} do
    inject_orchestrator(Module.concat(__MODULE__, :MissingDashboardOrchestrator), 5)

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  defp inject_orchestrator(name, timeout_ms) do
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

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
