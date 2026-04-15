import Config

# config/runtime.exs runs after compilation and before the system starts.
# Functions called here must be pure: no Application env reads, no GenServer
# calls, no side effects beyond file I/O. See docs/elixir_rules.md §
# "Runtime configuration".

if System.get_env("PHX_SERVER") do
  config :hortator, Web.Endpoint, server: true
end

config :hortator, Web.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Optional SSH config file path. `Transport.SSH` reads it from Application env.
config :hortator, :ssh_config, System.get_env("HORTATOR_SSH_CONFIG")

# Workflow-driven endpoint config. The entry point (escript `bin/hort`,
# `Core.CLI`) sets HORTATOR_WORKFLOW_FILE via `System.put_env/2` before
# invoking the runtime so this block can load the workflow and populate
# Application env for the endpoint.
case System.get_env("HORTATOR_WORKFLOW_FILE") do
  nil ->
    :ok

  path ->
    expanded = Path.expand(path)
    config :hortator, :workflow_file_path, expanded

    # Core.Workflow.load/1 is pure: reads the file, parses YAML, expands $VAR
    # references via System.get_env. Nothing else.
    case Core.Workflow.load(expanded) do
      {:ok, %{config: %{"server" => %{"port" => port} = server}}}
      when is_integer(port) and port >= 0 ->
        host = Map.get(server, "host", "127.0.0.1")

        ip =
          case host |> String.to_charlist() |> :inet.parse_address() do
            {:ok, ip} -> ip
            {:error, _} -> {127, 0, 0, 1}
          end

        config :hortator, Web.Endpoint,
          server: true,
          http: [ip: ip, port: port],
          url: [host: host]

      _ ->
        :ok
    end
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :hortator, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :hortator, Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
