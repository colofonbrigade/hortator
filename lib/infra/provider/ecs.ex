defmodule Infra.Provider.ECS do
  @moduledoc """
  AWS ECS worker provider. Manages Fargate tasks as SSH workers.
  Not yet implemented — see PRE-59.
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
