defmodule Schema.Config.Observability do
  @moduledoc """
  Struct definition for the observability section of WORKFLOW.md.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:dashboard_enabled, :boolean, default: true)
    field(:refresh_ms, :integer, default: 1_000)
    field(:render_interval_ms, :integer, default: 16)
  end
end
