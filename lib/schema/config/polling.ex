defmodule Schema.Config.Polling do
  @moduledoc """
  Struct definition for the polling section of WORKFLOW.md.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:interval_ms, :integer, default: 30_000)
  end
end
