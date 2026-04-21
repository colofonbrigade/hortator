defmodule Schema.Config.Agent do
  @moduledoc """
  Struct definition for the agent section of WORKFLOW.md.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:max_concurrent_agents, :integer, default: 10)
    field(:max_turns, :integer, default: 20)
    field(:max_retry_backoff_ms, :integer, default: 300_000)
    field(:max_concurrent_agents_by_state, :map, default: %{})
  end
end
