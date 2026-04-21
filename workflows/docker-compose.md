---
# Workflow for local Docker Compose workers.
#
# Uses git worktrees on a shared Docker volume: one bare clone at
# workspace_root/.bare, each issue gets a worktree. First issue
# bootstraps the bare clone; subsequent issues are near-instant.
#
# Operator flow:
#   make workers-up
#   ./bin/hort workflows/docker-compose.md
#   make workers-down
#
# Required env vars (set in your .env):
#   REPO_CLONE_URL        Clone URL (SSH recommended for push access)
#   LINEAR_PROJECT_SLUG   Linear project slug
#   GH_TOKEN              GitHub token for gh CLI (PR creation, comments)
#   HORTATOR_SSH_PUBKEY   Path to SSH public key for worker access

tracker:
  kind: linear
  project_slug: ${LINEAR_PROJECT_SLUG}

workspace:
  root: /home/worker/workspaces

polling:
  interval_ms: 5000

worker:
  provider: docker_compose
  ssh_hosts: ["127.0.0.1:2222", "127.0.0.1:2223"]
  max_concurrent_agents_per_host: 3
  docker_compose:
    file: deploy/docker-compose/docker-compose.yml
    replicas: 2

agent:
  max_concurrent_agents: 6
  max_turns: 20

claude:
  command: claude
  model: claude-sonnet-4-6
  permission_mode: bypassPermissions

hooks:
  after_create: |
    WORKSPACE_ROOT=$(dirname "$PWD")
    ISSUE_DIR=$(basename "$PWD")

    # Bootstrap bare clone on first use (idempotent)
    if [ ! -d "$WORKSPACE_ROOT/.bare" ]; then
      git clone --bare ${REPO_CLONE_URL} "$WORKSPACE_ROOT/.bare"
      echo "gitdir: ./.bare" > "$WORKSPACE_ROOT/.git"
      git -C "$WORKSPACE_ROOT" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
      git -C "$WORKSPACE_ROOT" config worktree.useRelativePaths true
    fi

    # Fetch latest (shared object store — just a delta)
    git -C "$WORKSPACE_ROOT" fetch origin

    # Create worktree with a fresh branch from the default branch
    cd "$WORKSPACE_ROOT"
    git worktree add "$ISSUE_DIR" -b "issue/$ISSUE_DIR" origin/main

    # Post-checkout setup
    cd "$ISSUE_DIR"
    if command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get 2>/dev/null || true
    fi
  before_remove: |
    WORKSPACE_ROOT=$(dirname "$PWD")
    ISSUE_DIR=$(basename "$PWD")

    # Close PRs for this branch if gh is available
    if command -v mix >/dev/null 2>&1; then
      mix workspace.before_remove 2>/dev/null || true
    fi

    # Remove the worktree (cleans up .bare metadata + deletes the dir)
    cd "$WORKSPACE_ROOT"
    git worktree remove "$ISSUE_DIR" --force 2>/dev/null || true
    git worktree prune 2>/dev/null || true

observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16

server:
  host: 127.0.0.1
  port: 4100
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Do not include "next steps for user" or "manual steps required" in any output.
4. When the work is complete, open a pull request using `gh pr create`.
5. Ensure the GitHub PR has label `hortator` (add it if missing).
6. After creating or updating the PR, use Linear MCP tools to move the issue to the appropriate review state.
