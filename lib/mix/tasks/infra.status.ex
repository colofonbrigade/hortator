defmodule Mix.Tasks.Infra.Status do
  use Boundary, classify_to: Infra
  use Mix.Task

  @shortdoc "List worker hosts and their health status"

  @moduledoc """
  List worker hosts and check their health.

  Usage:

      mix infra.status [workflow]

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

      case provider_module.list_hosts(config) do
        {:ok, hosts} when hosts == [] ->
          Mix.shell().info("No workers (provider: #{config.provider})")

        {:ok, hosts} ->
          Mix.shell().info("Workers (provider: #{config.provider}):\n")
          Mix.shell().info("  HOST                    STATUS")
          Mix.shell().info("  " <> String.duplicate("─", 40))
          print_host_statuses(hosts, provider_module)

        {:error, reason} ->
          Mix.raise("Failed to list workers: #{inspect(reason)}")
      end
    end
  end

  defp print_host_statuses(hosts, provider_module) do
    Enum.each(hosts, fn host ->
      status = provider_module.health_check(host)
      Mix.shell().info("  #{String.pad_trailing(host, 24)}#{status}")
    end)
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
              ssh_hosts: Map.get(worker, "ssh_hosts", []),
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
