---
# Workflow for local Docker Compose workers.
#
# Hortator runs on the host; agents run inside Docker containers reachable
# over SSH. The Infra.Provider.DockerCompose provider (PRE-58) manages
# container lifecycle; until then, start workers manually:
#
#   docker compose -f deploy/docker-compose/docker-compose.yml up -d --scale worker=2
#
# Required env vars (set in your .env alongside LINEAR_API_KEY):
#
#   REPO_CLONE_URL      Clone URL for the target repo (SSH or HTTPS)
#   LINEAR_PROJECT_SLUG Linear project slug
#   GITHUB_TOKEN        GitHub PAT for gh CLI (PR creation, comments)
#   HORTATOR_SSH_KEY    Path to SSH private key (default ~/.ssh/id_ed25519)
#
# Workspace paths are container-internal: /home/worker/workspaces/<issue-id>.

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
    # Configure HTTPS credential helper if GITHUB_TOKEN is available
    if [ -n "$GITHUB_TOKEN" ]; then
      git config --global credential.helper '!f() { echo "password=${GITHUB_TOKEN}"; }; f'
    fi
    git clone --depth 1 ${REPO_CLONE_URL} .
    if command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get 2>/dev/null || true
    fi
  before_remove: |
    if command -v mix >/dev/null 2>&1; then
      mix workspace.before_remove
    fi

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
