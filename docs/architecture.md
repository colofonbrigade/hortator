# Architecture Notes

Non-obvious patterns, naming decisions, and gotchas in the Hortator codebase.
Read this before making changes — it'll save you from the same mistakes we
already made and fixed.

## OTP app name vs module namespaces

The OTP application is `:hortator` but modules live under domain-named
namespaces: `Core.*`, `Web.*`, `Agents.*`, `Trackers.*`, etc. The only
module under the `Hortator` namespace is `Hortator.Application` (the
composition root). This means:

- `Application.get_env(:hortator, key)` — always `:hortator`, never `:core`.
- `config :hortator, Web.Endpoint, ...` — the first atom is the OTP app.
- If you see `:core` in an `Application.*_env` call, it's a bug from the
  Symphony port and should be `:hortator`.

## Escript behavior

`bin/hort` is an escript. Escripts do **not** evaluate `config/runtime.exs` —
all config is baked at compile time from `config/config.exs` + `config/dev.exs`.

The CLI entry point (`Core.CLI`) must call `Application.load(:hortator)`
**before** any `Application.put_env` calls, then `Application.ensure_all_started`.
Without the explicit `load`, `ensure_all_started` reloads defaults from the
`.app` spec and silently wipes any runtime env overrides. This bit us with the
endpoint not binding the correct port.

## Workflow files

There is no root-level `WORKFLOW.md`. The default workflow is
`workflows/TEMPLATE.md`. Additional workflows live as peers:
`workflows/smoke-test.md`, `workflows/docker-compose.md` (planned), etc.

`Core.Workflow.workflow_file_path/0` defaults to
`Path.join(File.cwd!(), "workflows/TEMPLATE.md")`. The escript and
`config/runtime.exs` can override via `HORTATOR_WORKFLOW_FILE` env var
or `Core.Workflow.set_workflow_file_path/1`.

## Module size rule

Every `lib/` file must be ≤300 LOC. The sole exception is the phx-generated
`lib/web/components/core_components.ex` (framework-owned).

Large modules are split into sub-modules under the same namespace:
- `Core.Orchestrator` → 8 sub-modules under `Core.Orchestrator.*`
- `Agents.Claude.Session` → `CommandBuilder` + `StreamParser`
- `CLI.StatusDashboard` → `Header` + `AgentTable` + `RetryQueue` + `Formatters`
- `Core.Config.Schema` → 9 section schemas + `Resolver` + `Errors`

When modifying behavior, find the right sub-module. Don't add to the
coordinator/parent unless it's genuinely coordination logic.

## Orchestrator decomposition

`Core.Orchestrator` is a thin GenServer that delegates to:

| Module | Responsibility |
|--|--|
| `Polling` | Tick scheduling, poll-cycle lifecycle |
| `Dispatch` | Candidate selection, agent spawning |
| `Reconciliation` | Running-issue state refresh, terminal teardown, stall detection |
| `Retry` | Exponential backoff, timer bookkeeping |
| `RetryHandler` | Coordinates retry → dispatch (sits above Retry + Dispatch + Reconciliation) |
| `Updates` | Agent stream-event integration, session totals |
| `WorkerPool` | SSH host capacity, least-loaded selection |
| `IssueFilter` | Pure predicates: terminal/active state, routability, blocker checks |
| `TokenAccounting` | Token/cost delta math (pure, no persistence) |

The public API is on `Core.Orchestrator` itself — `snapshot/2`,
`request_refresh/1`, plus `defdelegate` for test-facing helpers like
`dispatch_eligible?/2` and `sort_issues_for_dispatch/1`.

## Telemetry is deliberately absent

The Symphony fork removed the SQLite-backed telemetry store because the NIF
breaks the escript build. The `Core.Config.Schema.Observability` section no
longer has `telemetry_enabled` or `telemetry_db_path` fields.

Token accounting still runs **in-memory** via `Core.Orchestrator.TokenAccounting`
and `Agents.Claude.Usage` — both are pure data helpers with no persistence.
The plan is to report token usage to Linear via attachments (PRE-47) rather
than a local database.

Do not re-introduce `ecto_sqlite3` or any NIF-backed telemetry store. If you
need persistence, use an approach that doesn't break `mix escript.build`.

## Symphony provenance

Forked from `openai/symphony` at commit `9e89dd9`. Renamed:
- `Symphony` → `Hortator` (module names, strings, env vars, GraphQL op names)
- `:core` → `:hortator` (OTP app atom in all `Application.*_env` calls)
- `SYMPHONY_*` → `HORTATOR_*` (env vars)
- `__SYMPHONY_WORKSPACE__` → `__HORTATOR_WORKSPACE__` (remote workspace marker)
- `Claude` boundary → `Agents.Claude`, `Linear` boundary → `Trackers.Linear`

The `NOTICE` file documents the fork point and upstream attribution.

## Test patterns

- **`Core.TestSupport`**: macro loaded via `Code.require_file` in `test_helper.exs`.
  Provides a setup block that creates a temporary workflow file + env cleanup.
  Use `write_workflow_file!(path, overrides)` to generate test YAML.
- **`Test.Tracker.Memory`**: in-memory tracker adapter wired in `config/test.exs`
  via `config :hortator, Core.Tracker, adapter: Test.Tracker.Memory`. Seeds
  issues via `Application.put_env(:hortator, :memory_tracker_issues, [...])`.
- **Web test orchestrator injection**: inject a fake orchestrator per-test via
  `Application.put_env(:hortator, :endpoint_orchestrator, name)` +
  `Process.put(:endpoint_orchestrator, name)`. Both the controller and
  LiveView read this via `Utils.Runtime.get/2` (process-tree walk).
  Clean up in `on_exit` with `Application.delete_env`.
- **`config/test.exs`** silences `Core.StatusDashboard` rendering and swaps the
  tracker adapter. If you see terminal dashboard output during tests, check
  that `config :hortator, Core.StatusDashboard, render: false` is present.
- **E2E tests** (`test/core/live_e2e_test.exs`): gated on `HORTATOR_RUN_LIVE_E2E=1`.
  Creates a disposable Linear issue in the project named by
  `LINEAR_TEST_PROJECT_SLUG` — separate from `LINEAR_PROJECT_SLUG` so dev
  runs don't pollute the production project.

## Environment variables

Hortator reads env vars at two layers:

1. **Directly in code**: `LINEAR_API_KEY`, `LINEAR_ASSIGNEE` (via
   `Core.Config.Schema` `$VAR` resolution), `HORTATOR_WORKFLOW_FILE`,
   `HORTATOR_SSH_CONFIG`, `REPO_CLONE_URL` (via `workspace.before_remove`
   task — parses `owner/repo` slug from the clone URL).
2. **Via `${VAR}` placeholders in workflow YAML**: `LINEAR_PROJECT_SLUG`,
   `WORKSPACE_ROOT`, `REPO_CLONE_URL`, etc. Expanded by `Core.Workflow.load/1`
   at parse time.

See `.env.example` for the full documented list with explanations.

## Boundary compiler

The `:boundary` compiler is in `mix.exs`'s compilers list. Every top-level
namespace under `lib/` must declare `use Boundary` in its wrapper module
(`lib/core.ex`, `lib/web.ex`, `lib/agents.ex`, etc.).

`Hortator.Application` is a special top-level boundary (`top_level?: true`)
with `deps: [Core, Web]` — it's the only module allowed to reach across all
boundaries.

Sub-modules are classified into their parent boundary by prefix matching.
You don't need `use Boundary` on sub-modules unless you're creating a nested
boundary (which we don't do).

## Infra boundary (planned, not yet implemented)

PRE-57/58/59 introduce an `Infra` boundary for worker-host lifecycle
management. The design uses a `Infra.Provider` behaviour with implementations:
- `Infra.Provider.Static` — reads `worker.ssh_hosts` from workflow config (current behavior)
- `Infra.Provider.DockerCompose` — manages local Docker SSH workers
- `Infra.Provider.ECS` — manages AWS ECS Fargate tasks (future)

Infrastructure definitions (Dockerfiles, compose files, Terraform) live under
`deploy/`, not `lib/`. The Elixir provider modules only know how to talk to
the infrastructure, not define it.
