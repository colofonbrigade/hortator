defmodule Core.Orchestrator.IssueFilter do
  @moduledoc """
  Pure predicates for classifying tracker issues: active / terminal state
  membership, routability to this worker, blocker graph checks. Used by
  both the dispatch path and the reconciliation path.

  All functions are total, side-effect-free, and take their config inputs
  explicitly — the module never reads Application env. The `terminal_state_set/0`
  and `active_state_set/0` helpers that DO read `Core.Config` live here
  as a thin convenience so callers can pass the result into the predicates.
  """

  alias Core.Config
  alias Schema.Tracker.Issue

  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec active_state_set() :: MapSet.t()
  def active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  @spec terminal_issue_state?(String.t() | any(), MapSet.t()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @spec active_issue_state?(String.t(), MapSet.t()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  @spec issue_routable_to_worker?(Issue.t() | any()) :: boolean()
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  @spec candidate_issue?(Issue.t() | any(), MapSet.t(), MapSet.t()) :: boolean()
  def candidate_issue?(
        %Issue{
          id: id,
          identifier: identifier,
          title: title,
          state: state_name
        } = issue,
        active_states,
        terminal_states
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec todo_issue_blocked_by_non_terminal?(Issue.t() | any(), MapSet.t()) :: boolean()
  def todo_issue_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states
      )
      when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec retry_candidate_issue?(Issue.t(), MapSet.t()) :: boolean()
  def retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end
end
