defmodule Core.Config.Schema.Worker do
  @moduledoc """
  Embedded schema for the `worker:` section of WORKFLOW.md.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:ssh_hosts, {:array, :string}, default: [])
    field(:max_concurrent_agents_per_host, :integer)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
    |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
  end
end
