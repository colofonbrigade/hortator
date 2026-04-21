defmodule Mix.Tasks.Infra.Down do
  use Boundary, classify_to: Infra
  use Mix.Task

  @shortdoc "Tear down worker hosts for the configured provider"

  @moduledoc """
  Stop and remove worker hosts defined by the workflow's `worker.provider`.

  Usage:

      mix infra.down [workflow]

  Defaults to `workflows/TEMPLATE.md` when no workflow path is given.
  """

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [help: :boolean], aliases: [h: :help])

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      workflow_path = List.first(argv) || "workflows/TEMPLATE.md"
      {provider_module, config} = resolve_provider(workflow_path)

      Mix.shell().info("Stopping workers (provider: #{config.provider})...")

      case provider_module.stop_workers(config) do
        :ok -> Mix.shell().info("Workers stopped.")
        {:error, reason} -> Mix.raise("Failed to stop workers: #{inspect(reason)}")
      end
    end
  end

  defp resolve_provider(workflow_path) do
    case Workflow.load(Path.expand(workflow_path)) do
      {:ok, %{config: raw}} ->
        worker = Map.get(raw, "worker", %{})
        provider_name = Map.get(worker, "provider", "static")

        case Infra.Provider.resolve(provider_name) do
          {:ok, mod} ->
            config = %{
              provider: provider_name,
              compose_file: get_in(worker, ["docker_compose", "file"]) || "deploy/docker-compose/docker-compose.yml"
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
