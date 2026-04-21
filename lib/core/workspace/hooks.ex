defmodule Core.Workspace.Hooks do
  @moduledoc """
  Local hook execution for workspaces: runs shell commands with stdout/stderr
  capture, timeout handling, and environment variable propagation for lifecycle
  hooks (after_create, before_run, after_run, before_remove).
  """

  require Logger

  import Ecto.Changeset

  alias Core.Config
  alias Schema.Config.Hooks, as: HooksConfig

  @spec validate_workflow_config(HooksConfig.t(), map()) :: Ecto.Changeset.t()
  def validate_workflow_config(%HooksConfig{} = schema, attrs) do
    schema
    |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
    |> validate_number(:timeout_ms, greater_than: 0)
  end

  @spec run_local_hook(String.t(), Path.t(), map(), String.t()) :: :ok | {:error, term()}
  def run_local_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  @spec maybe_run_before_remove_hook(Path.t()) :: :ok | {:error, term()}
  def maybe_run_before_remove_hook(workspace) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_local_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  @spec handle_hook_command_result({iodata(), non_neg_integer()}, Path.t(), map(), String.t()) ::
          :ok | {:error, term()}
  def handle_hook_command_result({_output, 0}, _workspace, _issue_context, _hook_name) do
    :ok
  end

  def handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  @spec ignore_hook_failure(:ok | {:error, term()}) :: :ok
  def ignore_hook_failure(:ok), do: :ok
  def ignore_hook_failure({:error, _reason}), do: :ok

  @spec issue_log_context(map()) :: String.t()
  def issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end
end
