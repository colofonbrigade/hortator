defmodule Core.Orchestrator.Polling do
  @moduledoc """
  Tick scheduling and poll-cycle handlers for the orchestrator GenServer.
  The orchestrator keeps a single outstanding `:tick` timer identified by a
  fresh `tick_token` ref so late timer fires can be safely ignored.
  """

  alias Core.Config
  alias Core.Orchestrator.State

  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20

  @spec schedule_tick(State.t(), non_neg_integer()) :: State.t()
  def schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  @spec schedule_poll_cycle_start() :: :ok
  def schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  @spec refresh_runtime_config(State.t()) :: State.t()
  def refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  @spec clear_tick_markers(State.t()) :: State.t()
  def clear_tick_markers(%State{} = state) do
    %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }
  end
end
