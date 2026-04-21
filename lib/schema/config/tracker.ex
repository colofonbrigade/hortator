defmodule Schema.Config.Tracker do
  @moduledoc """
  Struct definition for the tracker section of WORKFLOW.md.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:kind, :string)
    field(:endpoint, :string, default: "https://api.linear.app/graphql")
    field(:api_key, :string)
    field(:project_slug, :string)
    field(:assignee, :string)
    field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
    field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
  end
end
