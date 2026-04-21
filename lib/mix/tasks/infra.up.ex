defmodule Mix.Tasks.Infra.Up do
  use Boundary, classify_to: Infra
  use Mix.Task

  @shortdoc "Start worker hosts for the configured provider"

  @moduledoc """
  Start worker hosts defined by the workflow's `worker.provider`.

  Usage:

      mix infra.up [workflow] [--replicas N]

  Defaults to `workflows/TEMPLATE.md` when no workflow path is given.
  """

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [replicas: :integer, help: :boolean], aliases: [h: :help])

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      workflow_path = List.first(argv) || "workflows/TEMPLATE.md"
      {provider_module, config} = resolve_provider(workflow_path, opts)

      Mix.shell().info("Starting workers (provider: #{config.provider})...")

      case provider_module.start_workers(config) do
        {:ok, hosts} ->
          Mix.shell().info("Workers started. Hosts:")
          Enum.each(hosts, &Mix.shell().info("  #{&1}"))

        {:error, reason} ->
          Mix.raise("Failed to start workers: #{inspect(reason)}")
      end
    end
  end

  defp resolve_provider(workflow_path, opts) do
    case Workflow.load(Path.expand(workflow_path)) do
      {:ok, %{config: raw}} ->
        worker = Map.get(raw, "worker", %{})
        provider_name = Map.get(worker, "provider", "static")

        case Infra.Provider.resolve(provider_name) do
          {:ok, mod} ->
            config = %{
              provider: provider_name,
              ssh_hosts: Map.get(worker, "ssh_hosts", []),
              compose_file: get_in(worker, ["docker_compose", "file"]) || "deploy/docker-compose/docker-compose.yml",
              replicas: opts[:replicas] || get_in(worker, ["docker_compose", "replicas"]) || 2
            }

            {mod, config}

          {:error, :unknown_provider} ->
            Mix.raise("Unknown provider: #{inspect(provider_name)}")
        end

      {:error, reason} ->
        Mix.raise("Failed to load workflow #{workflow_path}: #{inspect(reason)}")
    end
  end
end
