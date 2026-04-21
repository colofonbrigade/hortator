defmodule Infra do
  @moduledoc """
  Worker-host lifecycle management. Today contains `Infra.WorkerConfig`
  (worker section validation). Future: `Infra.Provider` behaviour,
  `Infra.HostManager` GenServer, provider implementations for Docker
  Compose, ECS, etc.
  """

  use Boundary, deps: [Schema, Utils], exports: [WorkerConfig]
end
