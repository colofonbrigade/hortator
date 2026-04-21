defmodule Schema.Config.Workspace do
  @moduledoc """
  Struct definition for the workspace section of WORKFLOW.md.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:root, :string, default: Path.join(System.tmp_dir!(), "hortator_workspaces"))
  end
end
