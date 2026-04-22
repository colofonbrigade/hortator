# Hortator

Hortator is an Elixir orchestrator that drives Claude Code agents against a Linear workspace. It polls a Linear project, spins up isolated per-issue workspaces, hands each to a Claude Code session, and keeps the session running until the work is done or the issue moves to a terminal state.

> [!WARNING]
> Hortator is an experimental engineering preview for testing in trusted
> environments. It's based on [`SPEC.md`](SPEC.md), forked from the
> [openai/symphony](https://github.com/openai/symphony) project (see
> [`NOTICE`](NOTICE) for attribution and the upstream commit).

## Architecture

Hortator is a Phoenix application whose lib/ is carved into one boundary per top-level namespace, enforced by the [`boundary`](https://hex.pm/packages/boundary) compiler (see [`docs/elixir_rules.md`](docs/elixir_rules.md) and [`docs/local_elixir_rules.md`](docs/local_elixir_rules.md)):

```
                        Hortator.Application
                       (composition root)
                      ────────────────────
                      ↓                 ↓
                    Core              Web
        ┌──────────┬─┴────┬──────┐     │ (Phoenix endpoint,
        ↓          ↓      ↓      ↓     │  observability API,
     Agents    Trackers  CLI   Utils   │  LiveView dashboard)
        │          │      │      │     │
        ├──────────┴──────┴──────┴─────┘
        ↓                  ↓
   Permissions ←───────→ Transport
       (leaf)              (SSH today)
                  ↓
                Schema (leaf — shared structs)
```

Peer backends live under single-purpose top-level boundaries: `Agents.Claude` today (Claude Code subprocess / SSH session), `Trackers.Linear` today (GraphQL client + adapter). Adding another tracker or agent backend is a new sub-namespace under the same parent boundary, without widening `Core`'s deps.

## Quickstart

```bash
cp .env.example .env          # fill in LINEAR_API_KEY, LINEAR_PROJECT_SLUG, WORKSPACE_ROOT, REPO_CLONE_URL
mise install                  # Elixir 1.19 / OTP 28
mix setup                     # deps + asset pipeline
MIX_ENV=prod mix assets.deploy        # bundle + digest priv/static
MIX_ENV=prod mix release --overwrite  # assemble _build/prod/rel/hortator
./bin/hort --i-understand-that-this-will-be-running-without-the-usual-guardrails workflows/TEMPLATE.md
```

`bin/hort` is a shell wrapper around the prod release at `_build/prod/rel/hortator/bin/hortator`. It requires a workflow path (no default) and expects the guardrails acknowledgement flag first. The wrapper manages a persistent `SECRET_KEY_BASE` cached at `${XDG_CACHE_HOME:-~/.cache}/hortator/secret_key_base`, then `exec`s the release with `HORTATOR_WORKFLOW_FILE` and `PHX_SERVER` exported — `config/runtime.exs` binds the Phoenix endpoint to the workflow's `server.port`.

Other workflows ship as peers (`workflows/smoke-test.md`, `workflows/docker-compose.md`). The workflow YAML front matter expands `${ENV_VAR}` placeholders at load time. See [`AGENTS.md`](AGENTS.md) for conventions and [`docs/`](docs/) for the full ruleset.

## Credit

Hortator is a fork of [Symphony](https://github.com/openai/symphony), the Elixir reference implementation that OpenAI released alongside the harness-engineering spec. This fork ports the domain logic onto a stock `phx.new` substrate, swaps the SQLite-backed telemetry for a lighter surface area, and restructures the boundary DAG so additional agent backends and tracker integrations can land as peer namespaces. See the [`NOTICE`](NOTICE) file for the full attribution line and upstream commit hash.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
