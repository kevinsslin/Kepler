---
tracker:
  kind: linear
  # Fill this with your Linear project slug from the project URL.
  # Example URL: https://linear.app/<workspace>/project/<slug>/...
  project_slug: "REPLACE_ME_PROJECT_SLUG"
  # Reads from env if omitted or set to $LINEAR_API_KEY
  api_key: $LINEAR_API_KEY
  # Optional: use "me" or a user id to shard workers by assignee
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done

polling:
  interval_ms: 5000

workspace:
  root: $SYMPHONY_WORKSPACE_ROOT

hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
  before_remove: |
    if [ -d elixir ]; then
      cd elixir && mise exec -- mix workspace.before_remove
    fi

agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_retry_backoff_ms: 300000

codex:
  command: "$CODEX_BIN --config model_reasoning_effort=high --model gpt-5.4 app-server"
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite

# Optional dashboard
# server:
#   port: 4020
#   host: 127.0.0.1
---

You are working on a Linear ticket `{{ issue.identifier }}`.

Title: {{ issue.title }}

{% if issue.description %}
Description:
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Follow the repository's workflow and quality checks. Keep ticket status and tracking comments up to date.
