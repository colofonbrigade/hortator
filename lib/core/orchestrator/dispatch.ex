defmodule Core.Orchestrator.Dispatch do
  @moduledoc """
  Candidate-issue selection, re-validation, and agent spawning.

  `maybe_dispatch/1` is the top-level poll-cycle entry point: it reconciles
  running issues first, then fetches and dispatches as many new candidates
  as orchestrator + worker slot math allows. Retry-triggered single-issue
  dispatches go through `dispatch_issue/4` directly.
  """

  require Logger

  import Ecto.Changeset

  alias Core.AgentRunner
  alias Core.Config
  alias Schema.Config.Agent, as: AgentConfig
  alias Core.Orchestrator.IssueFilter
  alias Core.Orchestrator.Reconciliation
  alias Core.Orchestrator.Retry
  alias Core.Orchestrator.State
  alias Core.Orchestrator.WorkerPool
  alias Core.Tracker
  alias Schema.Tracker.Issue

  @spec validate_workflow_config(AgentConfig.t(), map()) :: Ecto.Changeset.t()
  def validate_workflow_config(%AgentConfig{} = schema, attrs) do
    schema
    |> cast(
      attrs,
      [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
      empty_values: []
    )
    |> validate_number(:max_concurrent_agents, greater_than: 0)
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:max_retry_backoff_ms, greater_than: 0)
    |> update_change(:max_concurrent_agents_by_state, &normalize_state_limits/1)
    |> validate_state_limits(:max_concurrent_agents_by_state)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, Core.Orchestrator.IssueFilter.normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" -> [{field, "state names must not be blank"}]
          not is_integer(limit) or limit <= 0 -> [{field, "limits must be positive integers"}]
          true -> []
        end
      end)
    end)
  end

  @spec maybe_dispatch(State.t()) :: State.t()
  def maybe_dispatch(%State{} = state) do
    state = Reconciliation.reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- WorkerPool.available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, reason} ->
        log_dispatch_error(reason)
        state

      false ->
        state
    end
  end

  @spec dispatch_issue(State.t(), Issue.t(), integer() | nil, String.t() | nil) :: State.t()
  def dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           IssueFilter.terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  @doc """
  Re-fetch an issue by id through `issue_fetcher` and decide whether it's
  still dispatchable. Returns `{:ok, refreshed}` when dispatchable,
  `{:skip, refreshed}` when the refreshed issue is no longer a retry
  candidate (e.g. picked up a non-terminal blocker), `{:skip, :missing}`
  when the tracker no longer returns it, or `{:error, reason}` on fetch
  failure. Non-Issue inputs pass through as `{:ok, issue}`.
  """
  @spec revalidate_issue_for_dispatch(
          Issue.t() | term(),
          ([String.t()] -> term()),
          MapSet.t()
        ) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if IssueFilter.retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  @doc """
  Sort a list of candidate issues by dispatch priority (priority, then
  created_at ascending), producing the order the orchestrator will attempt.
  """
  @spec sort_issues_for_dispatch([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec dispatch_eligible?(Issue.t(), State.t()) :: boolean()
  def dispatch_eligible?(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, IssueFilter.active_state_set(), IssueFilter.terminal_state_set())
  end

  defp choose_issues(issues, state) do
    active_states = IssueFilter.active_state_set()
    terminal_states = IssueFilter.terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    IssueFilter.candidate_issue?(issue, active_states, terminal_states) and
      !IssueFilter.todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      WorkerPool.available_slots(state) > 0 and
      WorkerPool.state_slots_available?(issue, running) and
      WorkerPool.worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case WorkerPool.select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(Core.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running = Map.put(state.running, issue.id, new_running_entry(issue, pid, ref, worker_host, attempt))

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        Retry.schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp new_running_entry(%Issue{} = issue, pid, ref, worker_host, attempt) do
    %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: worker_host,
      workspace_path: nil,
      session_id: nil,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      agent_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      agent_cost_usd: 0.0,
      agent_last_reported_input_tokens: 0,
      agent_last_reported_output_tokens: 0,
      agent_last_reported_total_tokens: 0,
      turn_count: 0,
      rate_limit_info: nil,
      retry_attempt: Retry.normalize_retry_attempt(attempt),
      started_at: DateTime.utc_now()
    }
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp log_dispatch_error(:missing_linear_api_token),
    do: Logger.error("Linear API token missing in WORKFLOW.md")

  defp log_dispatch_error(:missing_linear_project_slug),
    do: Logger.error("Linear project slug missing in WORKFLOW.md")

  defp log_dispatch_error(:missing_tracker_kind),
    do: Logger.error("Tracker kind missing in WORKFLOW.md")

  defp log_dispatch_error({:unsupported_tracker_kind, kind}),
    do: Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

  defp log_dispatch_error({:invalid_workflow_config, message}),
    do: Logger.error("Invalid WORKFLOW.md config: #{message}")

  defp log_dispatch_error({:missing_workflow_file, path, reason}),
    do: Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")

  defp log_dispatch_error(:workflow_front_matter_not_a_map),
    do: Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")

  defp log_dispatch_error({:workflow_parse_error, reason}),
    do: Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")

  defp log_dispatch_error(reason),
    do: Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
end
