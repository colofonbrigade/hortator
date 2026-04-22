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

## Release packaging

`bin/hort` is a shell wrapper around the prod release at
`_build/prod/rel/hortator/bin/hortator`. It validates the guardrails
acknowledgement flag, resolves the workflow path to absolute, manages a
persistent `SECRET_KEY_BASE` cached at `${XDG_CACHE_HOME:-~/.cache}/hortator/`,
and `exec`s `bin/hortator start` with `HORTATOR_WORKFLOW_FILE` and `PHX_SERVER`
exported.

Releases evaluate `config/runtime.exs` at boot, so the workflow file can drive
the endpoint bind port/host there (see `config/runtime.exs`). `priv/static` is
bundled into the release tarball, so `Plug.Static` serves digested assets
without any escript-era workarounds.

Build with `MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release --overwrite`.

## Workflow files

There is no root-level `WORKFLOW.md`. The default workflow is
`workflows/TEMPLATE.md`. Additional workflows live as peers:
`workflows/smoke-test.md`, `workflows/docker-compose.md` (planned), etc.

`Core.Workflow.workflow_file_path/0` defaults to
`Path.join(File.cwd!(), "workflows/TEMPLATE.md")`. Override via the
`HORTATOR_WORKFLOW_FILE` env var (read by `config/runtime.exs`) or
`Core.Workflow.set_workflow_file_path/1` (used by tests).

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

## Infra boundary

`Infra.Provider` is the behaviour; implementations:
- `Infra.Provider.Static` — reads `worker.ssh_hosts` from workflow config
- `Infra.Provider.DockerCompose` — manages local Docker SSH workers via `docker compose`
- `Infra.Provider.ECS` — stub for AWS ECS Fargate tasks (future)

`Infra.HostManager` is a GenServer that caches the live host list. WorkerPool
reads from it on every scheduling decision. Operator commands:
`mix infra.up`, `mix infra.down`, `mix infra.status`.

Infrastructure definitions (Dockerfiles, compose files, Terraform) live under
`deploy/`, not `lib/`. The Elixir provider modules only know how to talk to
the infrastructure, not define it.

## Worker container credentials

Docker Compose workers receive two credential paths, both injected via `.env`
and docker-compose volume/env mounts:

**SSH key** (for `git clone git@github.com:...` / `git push`):
- Host key at `HORTATOR_SSH_KEY` (default `~/.ssh/id_ed25519`) is mounted
  read-only into the container.
- `entrypoint.sh` copies it to `/home/worker/.ssh/id_ed25519` with correct
  permissions (Docker bind-mounts don't preserve `chmod 600`).
- `GIT_SSH_COMMAND` is set to use the key with `StrictHostKeyChecking=no`.
- `github.com` is added to `known_hosts` via `ssh-keyscan` at container start.

**GitHub token** (for `gh` CLI — PR creation, comments, labels):
- `GITHUB_TOKEN` from `.env` is passed as both `GITHUB_TOKEN` and `GH_TOKEN`
  env vars. `gh` reads `GH_TOKEN` automatically without `gh auth login`.
- For HTTPS clone URLs, the entrypoint configures a git credential helper
  that returns the token.

**Verify auth inside a running worker:**
```bash
docker compose -f deploy/docker-compose/docker-compose.yml exec worker su - worker -c "gh auth status"
docker compose -f deploy/docker-compose/docker-compose.yml exec worker su - worker -c "ssh -T git@github.com"
```

Workers boot without either credential — SSH-only mode works for SSH clone
URLs without a token, and HTTPS-only mode works with just `GITHUB_TOKEN`.
`gh` commands fail clearly if the token is absent.

## Git worktree workspace model

Docker Compose workers use a **bare-clone + worktree** pattern instead of
cloning the repo per issue. This is based on the approach described at
https://gabri.me/blog/git-worktrees-done-right.

Layout on the shared volume:
```
/home/worker/workspaces/
├── .bare/          # bare clone of the target repo (shared git objects)
├── .git            # pointer file: "gitdir: ./.bare"
├── MT-123/         # git worktree for issue MT-123
├── MT-124/         # git worktree for issue MT-124
└── MT-125/         # git worktree for issue MT-125
```

The first issue dispatched to the volume bootstraps the bare clone
(idempotent guard in `hooks.after_create`). Subsequent issues create
worktrees from the shared `.bare` — near-instant, no network fetch
unless the branch target has advanced.

Each worktree is a full working copy with its own branch
(`issue/<identifier>`). Agents can commit, push, and create PRs
independently. `git worktree remove` in `hooks.before_remove` cleans
up both the directory and the worktree metadata.

The `workflows/TEMPLATE.md` still uses `git clone` (simple, no shared
state). The worktree pattern is used in `workflows/docker-compose.md`
where workers share a Docker volume.
