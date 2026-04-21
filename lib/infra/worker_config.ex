defmodule Infra.WorkerConfig do
  @moduledoc """
  Workflow-config validation for the `worker:` section of WORKFLOW.md.
  """

  import Ecto.Changeset

  alias Schema.Config.Worker, as: WorkerConfig

  @spec validate_workflow_config(WorkerConfig.t(), map()) :: Ecto.Changeset.t()
  def validate_workflow_config(%WorkerConfig{} = schema, attrs) do
    schema
    |> cast(attrs, [:provider, :ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
    |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    |> validate_inclusion(:provider, ["static", "docker_compose", "ecs"])
  end
end
