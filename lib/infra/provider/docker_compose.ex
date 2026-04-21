defmodule Infra.Provider.DockerCompose do
  @moduledoc """
  Docker Compose worker provider. Manages local SSH worker containers
  via `docker compose`.
  """

  @behaviour Infra.Provider

  require Logger

  @default_compose_file "deploy/docker-compose/docker-compose.yml"
  @default_replicas 2

  @impl true
  def start_workers(config) do
    file = compose_file(config)
    replicas = Map.get(config, :replicas, @default_replicas)

    case run_compose(file, ["up", "-d", "--scale", "worker=#{replicas}", "--build", "--wait"]) do
      {:ok, _output} -> list_hosts(config)
      {:error, reason} -> {:error, {:docker_compose_up_failed, reason}}
    end
  end

  @impl true
  def stop_workers(config) do
    file = compose_file(config)

    case run_compose(file, ["down"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:docker_compose_down_failed, reason}}
    end
  end

  @impl true
  def list_hosts(config) do
    file = compose_file(config)

    case run_compose(file, ["ps", "--format", "json", "--status", "running"]) do
      {:ok, output} -> {:ok, parse_host_ports(output)}
      {:error, reason} -> {:error, {:docker_compose_ps_failed, reason}}
    end
  end

  @impl true
  def health_check(host) when is_binary(host) do
    [h, p] = parse_host_port(host)

    case System.cmd("ssh", ["-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=3", "-p", p, "worker@#{h}", "echo ok"], stderr_to_stdout: true) do
      {_output, 0} -> :healthy
      _ -> :unhealthy
    end
  rescue
    _ -> :unhealthy
  end

  defp compose_file(config), do: Map.get(config, :compose_file, @default_compose_file)

  defp run_compose(file, args) do
    env_file = if File.exists?(".env"), do: ["--env-file", ".env"], else: []
    full_args = env_file ++ ["-f", file | args]
    Logger.debug("docker compose #{Enum.join(full_args, " ")}")

    case System.cmd("docker", ["compose" | full_args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        Logger.error("docker compose failed status=#{status}: #{String.slice(output, 0, 500)}")
        {:error, {:exit_status, status, output}}
    end
  end

  defp parse_host_ports(json_output) do
    json_output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"Publishers" => publishers}} when is_list(publishers) ->
          publishers
          |> Enum.filter(&(&1["TargetPort"] == 22 and &1["PublishedPort"] > 0))
          |> Enum.map(&"127.0.0.1:#{&1["PublishedPort"]}")

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp parse_host_port(host_port) do
    case String.split(host_port, ":") do
      [host, port] -> [host, port]
      _ -> [host_port, "22"]
    end
  end
end
