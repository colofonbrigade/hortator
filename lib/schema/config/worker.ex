defmodule Schema.Config.Worker do
  @moduledoc """
  Struct definition for the worker section of WORKFLOW.md.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:provider, :string, default: "static")
    field(:ssh_hosts, {:array, :string}, default: [])
    field(:max_concurrent_agents_per_host, :integer)
  end
end
