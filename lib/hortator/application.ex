defmodule Hortator.Application do
  @moduledoc """
  OTP application entrypoint. This is the composition root: it wires
  together children from every boundary (`Core`, `Web`, `Agents`,
  `Trackers`, and their peers) and is the only module allowed to reach
  across all of them.
  """

  use Boundary, top_level?: true, deps: [Core, Web, Workflow]
  use Application

  @impl true
  def start(_type, _args) do
    :ok = Core.LogFile.configure()

    children = [
      Web.Telemetry,
      {DNSCluster, query: Application.get_env(:hortator, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Core.PubSub},
      {Task.Supervisor, name: Core.TaskSupervisor},
      Workflow.Store,
      Core.Orchestrator,
      Core.StatusDashboard,
      Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    Core.StatusDashboard.render_offline_status()
    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
