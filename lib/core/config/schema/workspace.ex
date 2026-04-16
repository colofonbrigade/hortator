defmodule Core.Config.Schema.Workspace do
  @moduledoc """
  Embedded schema for the `workspace:` section of WORKFLOW.md.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:root, :string, default: Path.join(System.tmp_dir!(), "hortator_workspaces"))
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:root], empty_values: [])
  end
end
