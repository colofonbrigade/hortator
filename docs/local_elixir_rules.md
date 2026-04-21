# Local Elixir Rules (Hortator)

Project-specific boundary and structural rules for this repo. Applied in addition to the shared
ruleset in [`elixir_rules.md`](elixir_rules.md). If a rule here conflicts with the shared ruleset,
this file wins locally; consider whether the divergence should be upstreamed.

## Boundaries in this repo

- `Hortator.Application` — Composition root (top-level boundary, `deps: [Core, Web]`).
  The only module allowed to reach across all boundaries. Lives at
  `lib/hortator/application.ex`. Owns the supervision tree.
- `Core` — Orchestrator, agent runner, workspace management, workflow loader, status
  dashboard *coordinator* (the GenServer; rendering lives in `CLI`). The domain core.
  `Core.Orchestrator` is a thin GenServer that delegates to 8 sub-modules under
  `Core.Orchestrator.*` (Dispatch, Reconciliation, Retry, RetryHandler, Polling,
  Updates, WorkerPool, IssueFilter, TokenAccounting). See `docs/architecture.md`
  for the full decomposition.
- `Web` — Phoenix endpoint, LiveView dashboard, JSON observability API. Depends on
  `Core` + `Utils`.
- `Schema` — Shared structs used across boundaries (`Schema.Snapshot`, `Schema.Tracker.Issue`).
  Leaf: depends on nothing in-app.
- `Trackers` — Issue tracker integrations. Today: `Trackers.Linear` (GraphQL client via
  `Trackers.Linear.GraphQL`, query strings in `Trackers.Linear.Queries`, response decoder,
  tracker behaviour + adapter). `Core.Tracker` dispatches to the configured adapter, threading
  tracker settings in at call time. Future home for peer trackers (GitHub, Jira, etc.).
- `Agents` — Agent backends. Today: `Agents.Claude` (Claude Code subprocess/SSH session
  client, split into `Session`, `Session.CommandBuilder`, `Session.StreamParser`).
  Decoupled from Core: callers pass `claude` settings and `workspace_root` into
  `Agents.Claude.Session.start_session/2`. Depends on `Permissions` + `Transport`.
- `Transport` — Low-level communication primitives. Today: `Transport.SSH`. Leaf-ish:
  reads `:ssh_config` from Application env, no in-app deps.
- `Permissions` — Security-sensitive pure utilities. Today: `Permissions.PathSafety` (path
  traversal / symlink-escape guards). Leaf: no state, no config, no in-app deps.
- `CLI` — Pure terminal-UI rendering. `CLI.StatusDashboard` composes sections from
  `Header`, `AgentTable`, `RetryQueue`, and `Formatters` sub-modules; `Core.StatusDashboard`
  reads Config, builds the context, and writes the result to stdout. Depends on `Schema`;
  depended on by `Core`.
- `Utils` — Cross-cutting infrastructure helpers. Houses `Utils.Runtime`, a thin
  `ProcessTree` accessor with Application-env fallback. Leaf of the DAG; any boundary may
  depend on it. **Long-lived GenServers must not read config through `Utils.Runtime`** — the
  cache lives in their own dict and pins stale values. Such callers use `Application.get_env`
  directly (see `Core.Workflow.workflow_file_path/0`, `Core.Config.server_port/0`).
- `Infra` (planned, PRE-57) — Worker-host lifecycle management. `Infra.Provider` behaviour
  with implementations for Static (current), DockerCompose, ECS. `Infra.HostManager`
  GenServer tracks live hosts. Will be a leaf boundary depended on by `Core`.

