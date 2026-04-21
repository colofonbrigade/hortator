defmodule Core.Orchestrator.WorkerPool do
  @moduledoc """
  Worker-host scheduling for the orchestrator: capacity checks, preferred-host
  stickiness for retries, least-loaded fallback. Reads the live host list from
  `Infra.HostManager` and per-host concurrency caps from `Core.Config`.
  """

  alias Core.Config
  alias Core.Orchestrator.State
  alias Schema.Tracker.Issue

  @doc """
  Pick a worker host for a new agent, respecting per-host concurrency caps.
  Returns the preferred host when it has capacity, otherwise the least-loaded
  eligible host, or `:no_worker_capacity` when every host is full. Returns
  `nil` when the pool is unconfigured (local-only mode).
  """
  @spec select_worker_host(State.t(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host(%State{} = state, preferred_worker_host) do
    case Infra.HostManager.list_hosts() do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] -> :no_worker_capacity
          preferred_available?(preferred_worker_host, available_hosts) -> preferred_worker_host
          true -> least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  @spec worker_slots_available?(State.t()) :: boolean()
  def worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  @spec worker_slots_available?(State.t(), String.t() | nil) :: boolean()
  def worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  @spec available_slots(State.t()) :: non_neg_integer()
  def available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec dispatch_slots_available?(Issue.t(), State.t()) :: boolean()
  def dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  @spec state_slots_available?(Issue.t() | any(), map()) :: boolean()
  def state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _running), do: false

  @spec running_worker_host_count(map(), String.t()) :: non_neg_integer()
  def running_worker_host_count(running, worker_host)
      when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp preferred_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = Core.Orchestrator.IssueFilter.normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        Core.Orchestrator.IssueFilter.normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end
end
