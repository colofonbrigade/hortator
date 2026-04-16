defmodule Core.Orchestrator do
  @moduledoc """
  Polls the tracker and dispatches repository copies to Claude Code agents.

  This module is the GenServer skeleton and composition root. Behavioral
  concerns live in single-purpose helpers under `Core.Orchestrator.*`:

    * `Polling` — tick scheduling and poll-cycle lifecycle.
    * `Dispatch` — candidate selection, re-validation, agent spawning.
    * `Reconciliation` — running-issue state refresh, terminal-state teardown,
      workspace cleanup.
    * `Retry` — exponential-backoff retry bookkeeping.
    * `Updates` — incremental agent update events and session totals.
    * `WorkerPool` — worker-host capacity and selection.
    * `IssueFilter` — pure tracker-state predicates.
  """

  use GenServer
  require Logger

  alias Core.Orchestrator.Dispatch
  alias Core.Orchestrator.Polling
  alias Core.Orchestrator.Reconciliation
  alias Core.Orchestrator.Retry
  alias Core.Orchestrator.RetryHandler
  alias Core.Orchestrator.Updates
  alias Core.Orchestrator.WorkerPool
  alias Core.{Config, StatusDashboard}
  alias Schema.Snapshot

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      agent_totals: nil
    ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      agent_totals: Core.Orchestrator.TokenAccounting.empty_totals()
    }

    Reconciliation.run_terminal_workspace_cleanup()
    state = Polling.schedule_tick(state, 0)

    {:ok, state}
  end

  ## handle_info

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = state |> Polling.refresh_runtime_config() |> Polling.clear_tick_markers()
    notify_dashboard()
    :ok = Polling.schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = state |> Polling.refresh_runtime_config() |> Polling.clear_tick_markers()
    notify_dashboard()
    :ok = Polling.schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = Polling.refresh_runtime_config(state)
    state = Dispatch.maybe_dispatch(state)
    state = Polling.schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: running} = state) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {:noreply, handle_worker_down(state, issue_id, reason)}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> Retry.maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> Retry.maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_worker_update, issue_id, %{event: _, timestamp: _} = update},
        state
      ) do
    state = Updates.handle_agent_worker_update(state, issue_id, update)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    state =
      case Retry.pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} ->
          RetryHandler.handle_retry_issue(state, issue_id, attempt, metadata)

        :missing ->
          state
      end

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## handle_call

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = Polling.refresh_runtime_config(state)
    snapshot = Snapshot.build(state, DateTime.utc_now(), System.monotonic_time(:millisecond))
    {:reply, snapshot, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: Polling.schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  ## Public API

  @spec request_refresh() :: map() | :unavailable
  def request_refresh, do: request_refresh(__MODULE__)

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  # Re-exported helpers (tests and presenters rely on these public names).
  defdelegate reconcile_issue_states(issues, state), to: Reconciliation
  defdelegate dispatch_eligible?(issue, state), to: Dispatch
  defdelegate sort_issues_for_dispatch(issues), to: Dispatch
  defdelegate revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states), to: Dispatch
  defdelegate select_worker_host(state, preferred_worker_host), to: WorkerPool

  ## Private coordination helpers

  defp handle_worker_down(%State{} = state, issue_id, reason) do
    {running_entry, state} = pop_running_entry(state, issue_id)
    state = Updates.record_session_completion_totals(state, running_entry)
    session_id = running_entry_session_id(running_entry)

    state =
      case reason do
        :normal -> handle_normal_worker_exit(state, issue_id, running_entry, session_id)
        other -> handle_abnormal_worker_exit(state, issue_id, running_entry, session_id, other)
      end

    Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")
    notify_dashboard()
    state
  end

  defp handle_normal_worker_exit(state, issue_id, running_entry, session_id) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

    state
    |> Reconciliation.complete_issue(issue_id)
    |> Retry.schedule_issue_retry(issue_id, 1, %{
      identifier: running_entry.identifier,
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp handle_abnormal_worker_exit(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = Retry.next_retry_attempt_from_running(running_entry)

    Retry.schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp notify_dashboard, do: StatusDashboard.notify_update()

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp find_issue_id_for_ref(running, ref) do
    Enum.find_value(running, fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"
end
