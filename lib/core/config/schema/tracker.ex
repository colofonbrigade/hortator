defmodule Core.Config.Schema.Tracker do
  @moduledoc """
  Embedded schema for the `tracker:` section of WORKFLOW.md.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:kind, :string)
    field(:endpoint, :string, default: "https://api.linear.app/graphql")
    field(:api_key, :string)
    field(:project_slug, :string)
    field(:assignee, :string)
    field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
    field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(
      schema,
      attrs,
      [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states],
      empty_values: []
    )
  end
end
