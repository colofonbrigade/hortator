defmodule Core do
  @moduledoc """
  Entry point for the Hortator orchestrator and home of domain-core
  modules (orchestrator, agent runner, workspace, workflow loader,
  status dashboard).
  """

  use Boundary,
    deps: [CLI, Infra, Schema, Permissions, Transport, Agents, Trackers, Utils, Workflow],
    exports: [
      AgentRunner,
      Config,
      LogFile,
      ObservabilityPubSub,
      Orchestrator,
      PromptBuilder,
      SpecsCheck,
      StatusDashboard,
      Tracker,
      Workspace
    ]
end
