defmodule Schema.Config.Server do
  @moduledoc """
  Struct definition for the server section of WORKFLOW.md (optional
  Phoenix observability endpoint bind host/port).
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:port, :integer)
    field(:host, :string, default: "127.0.0.1")
  end
end
