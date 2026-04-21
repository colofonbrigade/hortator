defmodule Schema.Config do
  @moduledoc """
  Struct definition for the top-level WORKFLOW.md YAML front matter.
  Each section is an embedded sub-schema under `Schema.Config.*`.
  """

  use Ecto.Schema

  alias Schema.Config.Agent
  alias Schema.Config.Claude
  alias Schema.Config.Hooks
  alias Schema.Config.Observability
  alias Schema.Config.Polling
  alias Schema.Config.Server
  alias Schema.Config.Tracker
  alias Schema.Config.Worker
  alias Schema.Config.Workspace

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end
end
