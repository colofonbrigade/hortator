defmodule Core.Config do
  @moduledoc """
  Runtime configuration loaded from a workflow Markdown file. Reads the raw
  YAML map from `Workflow.Store`, parses it into a `%Schema.Config{}` struct
  by calling each domain module's `validate_workflow_config/2`, resolves
  `$VAR` env-var placeholders, and exposes convenience accessors.
  """

  import Ecto.Changeset

  alias Schema.Config, as: Cfg
  alias Workflow
  alias Workflow.Resolver

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type claude_runtime_settings :: %{
          command: String.t(),
          model: String.t(),
          permission_mode: String.t(),
          mcp_config_path: String.t() | nil,
          effort: String.t() | nil,
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }

  @spec settings() :: {:ok, Cfg.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Cfg.t()
  def settings! do
    case settings() do
      {:ok, settings} -> settings
      {:error, reason} -> raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      String.downcase(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:hortator, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec claude_runtime_settings() :: {:ok, claude_runtime_settings()} | {:error, term()}
  def claude_runtime_settings do
    with {:ok, settings} <- settings() do
      {:ok,
       %{
         command: settings.claude.command,
         model: settings.claude.model,
         permission_mode: settings.claude.permission_mode,
         mcp_config_path: settings.claude.mcp_config_path,
         effort: settings.claude.effort,
         turn_timeout_ms: settings.claude.turn_timeout_ms,
         read_timeout_ms: settings.claude.read_timeout_ms,
         stall_timeout_ms: settings.claude.stall_timeout_ms
       }}
    end
  end

  ## --- parse pipeline ---

  @spec parse(map()) :: {:ok, Cfg.t()} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> build_changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} -> {:ok, finalize_settings(settings)}
      {:error, changeset} -> {:error, {:invalid_workflow_config, format_changeset_errors(changeset)}}
    end
  end

  defp build_changeset(attrs) do
    %Cfg{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Core.Tracker.validate_workflow_config/2)
    |> cast_embed(:polling, with: &Core.Orchestrator.Polling.validate_workflow_config/2)
    |> cast_embed(:workspace, with: &Core.Workspace.validate_workflow_config/2)
    |> cast_embed(:worker, with: &Infra.WorkerConfig.validate_workflow_config/2)
    |> cast_embed(:agent, with: &Core.Orchestrator.Dispatch.validate_workflow_config/2)
    |> cast_embed(:claude, with: &Agents.Claude.Session.validate_workflow_config/2)
    |> cast_embed(:hooks, with: &Core.Workspace.Hooks.validate_workflow_config/2)
    |> cast_embed(:observability, with: &Core.StatusDashboard.validate_workflow_config/2)
    |> cast_embed(:server, with: &Workflow.validate_server_config/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: Resolver.resolve_secret(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: Resolver.resolve_secret(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: Resolver.resolve_path(settings.workspace.root, Path.join(System.tmp_dir!(), "hortator_workspaces"))
    }

    %{settings | tracker: tracker, workspace: workspace}
  end

  ## --- helpers ---

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) -> {:error, :missing_tracker_kind}
      settings.tracker.kind not in ["linear", "memory"] -> {:error, {:unsupported_tracker_kind, settings.tracker.kind}}
      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) -> {:error, :missing_linear_api_token}
      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) -> {:error, :missing_linear_project_slug}
      true -> :ok
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp format_changeset_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix = if prefix, do: prefix <> "." <> to_string(key), else: to_string(key)
      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} -> "Invalid WORKFLOW.md config: #{message}"
      {:missing_workflow_file, path, raw_reason} -> "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"
      {:workflow_parse_error, raw_reason} -> "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"
      :workflow_front_matter_not_a_map -> "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"
      other -> "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
