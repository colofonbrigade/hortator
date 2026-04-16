defmodule Core.Orchestrator.RetryHandler do
  @moduledoc """
  Coordinates the retry lifecycle: looking the issue up in the tracker,
  checking whether it's still dispatchable, and handing off to either
  `Dispatch.dispatch_issue/4` or `Retry.schedule_issue_retry/4` for the
  next iteration.

  This module lives above `Retry`, `Dispatch`, and `Reconciliation` in
  the call graph — `Reconciliation.reconcile_stalled_running_issues/1`
  calls `Retry.schedule_issue_retry/4` directly and never comes back
  through here, which keeps the dependency DAG acyclic.
  """

  require Logger

  alias Core.Orchestrator.Dispatch
  alias Core.Orchestrator.IssueFilter
  alias Core.Orchestrator.Reconciliation
  alias Core.Orchestrator.Retry
  alias Core.Orchestrator.State
  alias Core.Orchestrator.WorkerPool
  alias Core.Tracker
  alias Schema.Tracker.Issue

  @spec handle_retry_issue(State.t(), String.t(), integer(), map()) :: State.t()
  def handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        Retry.schedule_issue_retry(
          state,
          issue_id,
          attempt + 1,
          Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
        )
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = IssueFilter.terminal_state_set()

    cond do
      IssueFilter.terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        Reconciliation.cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        Reconciliation.release_issue_claim(state, issue_id)

      IssueFilter.retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        Reconciliation.release_issue_claim(state, issue_id)
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    Reconciliation.release_issue_claim(state, issue_id)
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if IssueFilter.retry_candidate_issue?(issue, IssueFilter.terminal_state_set()) and
         WorkerPool.dispatch_slots_available?(issue, state) and
         WorkerPool.worker_slots_available?(state, metadata[:worker_host]) do
      Dispatch.dispatch_issue(state, issue, attempt, metadata[:worker_host])
    else
      Logger.debug("No available slots for retrying issue_id=#{issue.id} issue_identifier=#{issue.identifier}; retrying again")

      Retry.schedule_issue_retry(
        state,
        issue.id,
        attempt + 1,
        Map.merge(metadata, %{
          identifier: issue.identifier,
          error: "no available orchestrator slots"
        })
      )
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} -> true
      _ -> false
    end)
  end
end
