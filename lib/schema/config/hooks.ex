defmodule Schema.Config.Hooks do
  @moduledoc """
  Struct definition for the hooks section of WORKFLOW.md (shell commands
  run at workspace lifecycle transitions).
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:after_create, :string)
    field(:before_run, :string)
    field(:after_run, :string)
    field(:before_remove, :string)
    field(:timeout_ms, :integer, default: 60_000)
  end
end
