defmodule Core.Orchestrator.Updates do
  @moduledoc """
  Handlers for incremental agent lifecycle messages: `:agent_worker_update`
  stream events (session started, token usage, rate-limit notifications)
  and session-completion totals accounting.
  """

  alias Core.Orchestrator.State
  alias Core.Orchestrator.TokenAccounting

  @spec handle_agent_worker_update(State.t(), String.t(), map()) :: State.t()
  def handle_agent_worker_update(
        %State{running: running} = state,
        issue_id,
        %{
          event: _,
          timestamp: _
        } = update
      ) do
    case Map.get(running, issue_id) do
      nil ->
        state

      running_entry ->
        {updated_running_entry, token_delta, cost_delta} =
          TokenAccounting.integrate_update(running_entry, update)

        state
        |> TokenAccounting.apply_agent_token_delta(token_delta)
        |> TokenAccounting.apply_agent_cost_delta(cost_delta)
        |> put_running_entry(issue_id, updated_running_entry)
    end
  end

  @spec record_session_completion_totals(State.t(), map() | term()) :: State.t()
  def record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    agent_totals =
      TokenAccounting.apply_token_delta(state.agent_totals, %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: runtime_seconds
      })

    %{state | agent_totals: agent_totals}
  end

  def record_session_completion_totals(state, _running_entry), do: state

  defp put_running_entry(%State{running: running} = state, issue_id, running_entry) do
    %{state | running: Map.put(running, issue_id, running_entry)}
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at)
  end

  defp running_seconds(_started_at, _now), do: 0
end
