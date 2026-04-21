defmodule Infra do
  @moduledoc """
  Worker-host lifecycle management. `Infra.Provider` is the behaviour;
  `Infra.HostManager` is the GenServer that holds the live host list.
  `Infra.WorkerConfig` validates the `worker:` section of workflow YAML.
  """

  use Boundary, deps: [Schema, Utils, Workflow], exports: [HostManager, Provider, WorkerConfig]
end
