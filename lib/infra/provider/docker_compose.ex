defmodule Infra.Provider.DockerCompose do
  @moduledoc """
  Docker Compose worker provider. Manages local SSH worker containers
  via `docker compose`. Not yet implemented — see PRE-58.
  """

  @behaviour Infra.Provider

  @impl true
  def start_workers(_config), do: {:error, :not_implemented}

  @impl true
  def stop_workers(_config), do: {:error, :not_implemented}

  @impl true
  def list_hosts(_config), do: {:error, :not_implemented}

  @impl true
  def health_check(_host), do: :unknown
end
