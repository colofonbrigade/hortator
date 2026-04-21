defmodule Infra.Provider.Static do
  @moduledoc """
  Null provider: returns `ssh_hosts` from the config map passed by
  `Infra.HostManager` at init. No lifecycle management — hosts are
  assumed to be pre-provisioned and always available.
  """

  @behaviour Infra.Provider

  @impl true
  def start_workers(config), do: {:ok, Map.get(config, :ssh_hosts, [])}

  @impl true
  def stop_workers(_config), do: :ok

  @impl true
  def list_hosts(config), do: {:ok, Map.get(config, :ssh_hosts, [])}

  @impl true
  def health_check(_host), do: :unknown
end
