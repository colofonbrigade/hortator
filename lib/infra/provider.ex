defmodule Infra.Provider do
  @moduledoc """
  Behaviour for worker-host lifecycle providers.

  Each provider knows how to start, stop, list, and health-check a pool
  of SSH-reachable worker hosts. The host list uses `"host:port"` strings
  — the same format `Transport.SSH` and `Core.Orchestrator.WorkerPool`
  already work with.
  """

  @type config :: map()

  @callback start_workers(config()) :: {:ok, [String.t()]} | {:error, term()}
  @callback stop_workers(config()) :: :ok | {:error, term()}
  @callback list_hosts(config()) :: {:ok, [String.t()]} | {:error, term()}
  @callback health_check(String.t()) :: :healthy | :unhealthy | :unknown

  @spec resolve(String.t() | nil) :: {:ok, module()} | {:error, :unknown_provider}
  def resolve("static"), do: {:ok, Infra.Provider.Static}
  def resolve("docker_compose"), do: {:ok, Infra.Provider.DockerCompose}
  def resolve("ecs"), do: {:ok, Infra.Provider.ECS}
  def resolve(nil), do: {:ok, Infra.Provider.Static}
  def resolve(_), do: {:error, :unknown_provider}
end
