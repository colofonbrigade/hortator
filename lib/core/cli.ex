defmodule Core.CLI do
  @moduledoc """
  Escript entrypoint for running Hortator with a workflow Markdown file.
  Defaults to `workflows/TEMPLATE.md` relative to cwd; pass a path to use a
  different workflow (e.g. `workflows/smoke-test.md` or one you've authored).
  """

  alias Core.{LogFile, Workflow}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("workflows/TEMPLATE.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      # Load :hortator first so put_env overrides survive into application start.
      # Without this, Application.start reloads defaults from the .app spec and
      # wipes any runtime env we set before ensure_all_started.
      _ = Application.load(:hortator)

      :ok = deps.set_workflow_file_path.(expanded_path)
      :ok = apply_workflow_endpoint_config(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Hortator with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: hort [--logs-root <path>] [--port <port>] [path-to-workflow.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:hortator) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Hortator implementation is a low-key engineering preview.",
      "Claude Code will run without any guardrails.",
      "Hortator is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:hortator, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:hortator, :server_port_override, port)
    :ok
  end

  # Mirror the workflow-driven endpoint config that config/runtime.exs applies
  # when running under `mix`. Escripts don't evaluate runtime.exs, so we do the
  # same pure load + Application.put_env here before the endpoint starts. The
  # --port CLI flag takes precedence over the workflow's server.port.
  defp apply_workflow_endpoint_config(path) do
    server = load_workflow_server(path)
    port = effective_port(server)

    if is_integer(port) do
      configure_endpoint(server, port)
    end

    :ok
  end

  defp load_workflow_server(path) do
    case Workflow.load(path) do
      {:ok, %{config: %{"server" => %{} = server}}} -> server
      _ -> %{}
    end
  end

  defp effective_port(server) do
    override = Application.get_env(:hortator, :server_port_override)
    workflow = Map.get(server, "port")

    cond do
      is_integer(override) and override >= 0 -> override
      is_integer(workflow) and workflow >= 0 -> workflow
      true -> nil
    end
  end

  defp configure_endpoint(server, port) do
    host = Map.get(server, "host", "127.0.0.1")
    ip = parse_ip(host)

    merged =
      :hortator
      |> Application.get_env(Web.Endpoint, [])
      |> Keyword.put(:server, true)
      |> Keyword.put(:http, ip: ip, port: port)
      |> Keyword.put(:url, host: host)

    Application.put_env(:hortator, Web.Endpoint, merged)
  end

  defp parse_ip(host) do
    case host |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(Core.Supervisor) do
      nil ->
        IO.puts(:stderr, "Hortator supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
