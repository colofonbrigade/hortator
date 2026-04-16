defmodule Agents.Claude.Session.CommandBuilder do
  @moduledoc """
  Builds and launches the `claude` CLI subprocess — locally via `Port.open`
  under `bash`, or remotely via `Transport.SSH.start_port/3`. Encapsulates
  argv construction (`launch_command_string/1`), workspace-path validation
  (local + remote), shell escaping, and the metadata snapshot we attach to
  every emitted stream event.
  """

  alias Permissions.PathSafety
  alias Transport.SSH

  @port_line_bytes 1_048_576

  @spec validate_workspace_cwd(Path.t(), String.t() | nil, Path.t() | nil) ::
          {:ok, Path.t()} | {:error, tuple()}
  def validate_workspace_cwd(workspace, nil, workspace_root)
      when is_binary(workspace) and is_binary(workspace_root) do
    case PathSafety.validate_workspace_in_root(workspace, workspace_root) do
      {:ok, canonical_workspace} ->
        {:ok, canonical_workspace}

      {:error, {:workspace_equals_root, canonical_workspace, _canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

      {:error, {:symlink_escape, expanded_workspace, canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

      {:error, {:outside_root, canonical_workspace, canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}

      {:error, {:path_unreadable, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  def validate_workspace_cwd(workspace, worker_host, _workspace_root)
      when is_binary(workspace) and is_binary(worker_host) do
    case PathSafety.validate_remote_workspace(workspace) do
      :ok ->
        {:ok, workspace}

      {:error, :empty} ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      {:error, :invalid_characters} ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}
    end
  end

  @spec start_port(Path.t(), String.t() | nil, map()) :: {:ok, port()} | {:error, term()}
  def start_port(workspace, nil, claude) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(launch_command_string(claude))],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  def start_port(workspace, worker_host, claude) when is_binary(worker_host) do
    remote_command =
      [
        "cd #{shell_escape(workspace)}",
        "exec #{launch_command_string(claude)}"
      ]
      |> Enum.join(" && ")

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  @spec stop_port(port()) :: :ok
  def stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  @spec port_metadata(port(), String.t() | nil) :: map()
  def port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{claude_session_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp launch_command_string(settings) do
    base = settings.command || "claude"

    fixed_args = [
      "--print",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      shell_escape(settings.permission_mode),
      "--model",
      shell_escape(settings.model)
    ]

    optional_args =
      []
      |> append_optional("--effort", settings.effort)
      |> append_optional("--mcp-config", settings.mcp_config_path)

    Enum.join([base | fixed_args ++ optional_args], " ")
  end

  defp append_optional(args, _flag, nil), do: args
  defp append_optional(args, _flag, ""), do: args

  defp append_optional(args, flag, value) when is_binary(value) do
    args ++ [flag, shell_escape(value)]
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp shell_escape(value) when is_atom(value), do: shell_escape(Atom.to_string(value))
end
