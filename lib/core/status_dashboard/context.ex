defmodule Core.StatusDashboard.Context do
  @moduledoc """
  Helpers that gather runtime context and orchestrator snapshots for the
  status dashboard. Extracted from `Core.StatusDashboard` to keep the
  GenServer module focused on lifecycle and rendering logic.
  """

  alias Core.{Config, Orchestrator}
  alias CLI.StatusDashboard, as: Renderer

  @doc """
  Reads the current `Config.settings!/0` and returns a map of dashboard-relevant
  configuration values.
  """
  @spec render_context() :: map()
  def render_context do
    settings = Config.settings!()

    %{
      max_agents: settings.agent.max_concurrent_agents,
      dashboard_host: settings.server.host,
      dashboard_port: Core.Config.server_port(),
      project_slug: settings.tracker.project_slug
    }
  end

  @doc """
  Calls `Orchestrator.snapshot/0` and normalises the result into
  `{:ok, snapshot_map}` or `:error`.
  """
  @spec snapshot_payload() :: {:ok, map()} | :error
  def snapshot_payload do
    if Process.whereis(Orchestrator) do
      case Orchestrator.snapshot() do
        %{
          running: running,
          retrying: retrying,
          agent_totals: agent_totals
        } = snapshot
        when is_list(running) and is_list(retrying) ->
          {:ok,
           %{
             running: running,
             retrying: retrying,
             agent_totals: agent_totals,
             polling: Map.get(snapshot, :polling)
           }}

        _ ->
          :error
      end
    else
      :error
    end
  end

  @doc """
  Fetches a snapshot and updates the rolling token-sample window.

  Returns `{snapshot_result, updated_token_samples}`.
  """
  @spec snapshot_with_samples(list(), integer()) :: {term(), list()}
  def snapshot_with_samples(token_samples, now_ms) do
    case snapshot_payload() do
      {:ok, %{running: running, retrying: retrying, agent_totals: agent_totals} = snapshot} ->
        total_tokens = Map.get(agent_totals, :total_tokens, 0)

        {
          {:ok,
           %{
             running: running,
             retrying: retrying,
             agent_totals: agent_totals,
             polling: Map.get(snapshot, :polling)
           }},
          Renderer.update_token_samples(token_samples, now_ms, total_tokens)
        }

      :error ->
        {
          :error,
          Renderer.prune_samples(token_samples, now_ms)
        }
    end
  end

  @doc """
  Extracts `total_tokens` from a snapshot result tuple, defaulting to `0`.
  """
  @spec snapshot_total_tokens(term()) :: non_neg_integer()
  def snapshot_total_tokens({:ok, %{agent_totals: agent_totals}}) when is_map(agent_totals) do
    Map.get(agent_totals, :total_tokens, 0)
  end

  def snapshot_total_tokens(_snapshot_data), do: 0
end
