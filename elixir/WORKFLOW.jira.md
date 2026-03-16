---
tracker:
  # Jira Cloud sample workflow. Use one Jira project per workflow file.
  kind: jira
  # Base Jira Cloud URL. The current reference implementation supports *.atlassian.net only.
  site_url: $JIRA_SITE_URL
  # Project key to scope both reads and writes.
  project_key: $JIRA_PROJECT_KEY
  # Recommended. If you override this, use a Jira account ID.
  assignee: me
  auth:
    # Jira Cloud currently supports api_token auth only.
    type: api_token
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
  # Optional: customize this if your Jira instance uses a different blocker link name.
  # link_types:
  #   blocks_inward:
  #     - is blocked by
  state_map:
    queued:
      - Todo
    active:
      - In Progress
    review:
      - Human Review
    merge:
      - Merging
    rework:
      - Rework
    terminal:
      - Done
      - Cancelled
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a tracker ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in a dispatchable state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Semantic status: {{ issue.semantic_state }}
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
2. Use `tracker_*` tools for issue reads, comments, transitions, links, and attachments.
3. Use `jira_rest` only when a high-level tracker tool is insufficient and keep requests inside the configured project.
4. Final message must report completed actions and blockers only. Do not include "next steps for user".
