defmodule Schema do
  @moduledoc """
  Shared data structures used across boundary lines. Leaf of the DAG:
  depends on nothing in-app. See `docs/elixir_rules.md` § "The Schema
  boundary" for what belongs here.
  """

  use Boundary,
    deps: [],
    exports: [
      Config,
      Config.Agent,
      Config.Claude,
      Config.Hooks,
      Config.Observability,
      Config.Polling,
      Config.Server,
      Config.Tracker,
      Config.Worker,
      Config.Workspace,
      Snapshot,
      Tracker.Issue
    ]
end
