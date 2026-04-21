defmodule Infra.HostManager do
  @moduledoc """
  GenServer that owns the live worker-host list.

  Receives the worker config (provider name + ssh_hosts) as an init arg
  from `Hortator.Application`. Resolves the provider, calls
  `start_workers/1`, and caches the host list.

  `list_hosts/0` is the public read path —
  `Core.Orchestrator.WorkerPool` calls it on every scheduling decision.

  On terminate, calls `stop_workers/1` so providers that manage
  container or cloud lifecycles can tear down cleanly.
  """

  use GenServer
  require Logger

  alias Infra.Provider

  defmodule State do
    @moduledoc false
    defstruct [:provider, :config, hosts: []]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list_hosts() :: [String.t()]
  def list_hosts, do: list_hosts(__MODULE__)

  @spec list_hosts(GenServer.server()) :: [String.t()]
  def list_hosts(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(server, :list_hosts)
      nil -> []
    end
  end

  @spec refresh() :: :ok | {:error, term()}
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @impl true
  def init(opts) do
    provider_name = Keyword.get(opts, :provider, "static")
    ssh_hosts = Keyword.get(opts, :ssh_hosts, [])
    config = %{ssh_hosts: ssh_hosts, provider: provider_name}

    case Provider.resolve(provider_name) do
      {:ok, provider_module} ->
        case provider_module.start_workers(config) do
          {:ok, hosts} ->
            Logger.info("Infra.HostManager started provider=#{provider_name} hosts=#{length(hosts)}")
            {:ok, %State{provider: provider_module, config: config, hosts: hosts}}

          {:error, reason} ->
            Logger.error("Infra.HostManager failed to start workers provider=#{provider_name}: #{inspect(reason)}")
            {:ok, %State{provider: provider_module, config: config, hosts: []}}
        end

      {:error, :unknown_provider} ->
        Logger.error("Infra.HostManager unknown provider=#{inspect(provider_name)}")
        {:ok, %State{provider: Infra.Provider.Static, config: config, hosts: []}}
    end
  end

  @impl true
  def handle_call(:list_hosts, _from, %State{hosts: hosts} = state) do
    {:reply, hosts, state}
  end

  def handle_call(:refresh, _from, %State{provider: provider} = state) do
    config = refresh_config(state.config)

    case provider.list_hosts(config) do
      {:ok, hosts} ->
        {:reply, :ok, %{state | config: config, hosts: hosts}}

      {:error, reason} ->
        Logger.warning("Infra.HostManager refresh failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %State{provider: provider, config: config}) do
    provider.stop_workers(config)
    :ok
  end

  defp refresh_config(%{provider: provider_name} = _old_config) do
    case Workflow.Store.current() do
      {:ok, %{config: raw}} when is_map(raw) ->
        worker = Map.get(raw, "worker", %{})
        %{provider: provider_name, ssh_hosts: Map.get(worker, "ssh_hosts", [])}

      _ ->
        %{provider: provider_name, ssh_hosts: []}
    end
  end
end
