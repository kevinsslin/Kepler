# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured issue tracker for candidate work
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves tracker tools:

- `tracker_*` high-level tools for issue reads, comments, transitions, links, and attachments
- `linear_graphql` for raw Linear GraphQL access
- `jira_rest` for allowlisted Jira Cloud REST access

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Choose a tracker:
   - Linear: create a personal API key and set `LINEAR_API_KEY`.
   - Jira Cloud: create an Atlassian API token, then set `JIRA_EMAIL`, `JIRA_API_TOKEN`,
     `JIRA_SITE_URL`, and `JIRA_PROJECT_KEY`.
3. Copy one of this directory's workflow samples to your repo:
   - `WORKFLOW.md` for Linear
   - `WORKFLOW.jira.md` for Jira Cloud
4. Optionally copy the `commit`, `push`, `pull`, `land`, `linear`, and `jira` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` tool.
   - The `jira` skill expects Symphony's `tracker_*` tools and `jira_rest`.
5. Customize the copied workflow file for your project.
   - Linear: use your project's slug in `tracker.project_slug`.
   - Jira: use your site's `.atlassian.net` URL in `tracker.site_url` and the project key in
     `tracker.project_key`.
   - For either tracker, map your real workflow states under `tracker.state_map`.
   - For Jira, keep one workflow file per project and prefer `assignee: me` unless you
     intentionally want to pin the workflow to a specific Jira account ID.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

If you are using the Jira sample without renaming it:

```bash
mise exec -- ./bin/symphony ./WORKFLOW.jira.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The workflow file uses YAML front matter for configuration, plus a Markdown body used as the Codex
session prompt.

Minimal Linear example:

```md
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "..."
  assignee: $LINEAR_ASSIGNEE
  state_map:
    queued: [Todo]
    active: [In Progress]
    review: [Human Review]
    merge: [Merging]
    rework: [Rework]
    terminal: [Done, Closed, Cancelled, Canceled, Duplicate]
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a tracker issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Minimal Jira Cloud example:

```md
---
tracker:
  kind: jira
  site_url: https://your-company.atlassian.net
  project_key: ENG
  assignee: me
  auth:
    type: api_token
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
  state_map:
    queued: [Todo]
    active: [In Progress]
    review: [Human Review]
    merge: [Merging]
    rework: [Rework]
    terminal: [Done, Cancelled]
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
codex:
  command: codex app-server
---

You are working on tracker issue {{ issue.identifier }}.

State: {{ issue.state }}
Title: {{ issue.title }}
Body: {{ issue.description }}
```

## Tracker configuration reference

For new workflows, prefer `tracker.state_map`. The older `tracker.active_states` and
`tracker.terminal_states` fields still work, but they are legacy compatibility fields.

### Shared tracker fields

| Field | Required | Applies to | Notes |
| --- | --- | --- | --- |
| `tracker.kind` | Yes | Linear, Jira | `linear` or `jira`. |
| `tracker.assignee` | No | Linear, Jira | Shared assignee filter. `me` is recommended. Jira also supports `JIRA_ASSIGNEE`; if you override `me`, use a Jira account ID. |
| `tracker.state_map` | Recommended | Linear, Jira | Semantic workflow routing map. Preferred over `active_states` / `terminal_states`. |
| `tracker.active_states` | Legacy | Linear, Jira | Fallback used only when `tracker.state_map` is omitted. |
| `tracker.terminal_states` | Legacy | Linear, Jira | Fallback used only when `tracker.state_map` is omitted. |

`tracker.state_map` uses these semantic keys:

| Semantic key | Meaning | Dispatches work |
| --- | --- | --- |
| `backlog` | Out of scope / parked work | No |
| `queued` | Ready to start | Yes |
| `active` | Actively being worked | Yes |
| `review` | Waiting for human review | No |
| `merge` | Approved / merge in progress | Yes |
| `rework` | Feedback-driven follow-up work | Yes |
| `terminal` | Fully done / cancelled | No; used for cleanup |

When `tracker.state_map` is present:

- Symphony derives candidate states from `queued`, `active`, `merge`, and `rework`.
- Symphony derives cleanup / stop states from `terminal`.
- `review` and `backlog` are valid semantic states, but they are not dispatchable.

### Linear configuration

| Field | Required | Env fallback | Notes |
| --- | --- | --- | --- |
| `tracker.endpoint` | No | none | Defaults to `https://api.linear.app/graphql`. |
| `tracker.api_key` | Yes | `LINEAR_API_KEY` | Can be omitted from the file if `LINEAR_API_KEY` is exported. |
| `tracker.project_slug` | Yes | none | Linear project `slugId`. |
| `tracker.assignee` | No | `LINEAR_ASSIGNEE` | Use `me` to follow the current Linear user, or a tracker-specific assignee value if your workflow needs it. |

Minimal env-backed Linear tracker block:

```yaml
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: your-project-slug
  assignee: $LINEAR_ASSIGNEE
  state_map:
    queued: [Todo]
    active: [In Progress]
    review: [Human Review]
    merge: [Merging]
    rework: [Rework]
    terminal: [Done, Closed, Cancelled, Canceled, Duplicate]
```

### Jira Cloud configuration

Jira support in the current reference implementation is intentionally narrow:

- Jira Cloud only (`*.atlassian.net`)
- one Jira project per workflow file
- API-token auth only
- the common case is `assignee: me`, so Symphony only works issues assigned to the authenticated user

| Field | Required | Env fallback | Notes |
| --- | --- | --- | --- |
| `tracker.site_url` | Yes | `JIRA_SITE_URL` | Base Jira Cloud URL, for example `https://your-company.atlassian.net`. |
| `tracker.project_key` | Yes | `JIRA_PROJECT_KEY` | Single Jira project to poll and mutate. |
| `tracker.assignee` | Recommended | `JIRA_ASSIGNEE` | Prefer `me`. If you set a fixed assignee, use a Jira account ID so reconciliation stays exact. |
| `tracker.auth.type` | Yes | none | Currently only `api_token` is supported. |
| `tracker.auth.email` | Yes | `JIRA_EMAIL` | Atlassian account email for the API token. |
| `tracker.auth.api_token` | Yes | `JIRA_API_TOKEN` | Atlassian API token. |
| `tracker.link_types.blocks_inward` | No | none | Optional list of Jira inward link names that should count as blockers. Defaults to `is blocked by`. |

Copy-ready Jira tracker block:

```yaml
tracker:
  kind: jira
  site_url: $JIRA_SITE_URL
  project_key: $JIRA_PROJECT_KEY
  assignee: me
  auth:
    type: api_token
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
  link_types:
    blocks_inward:
      - is blocked by
  state_map:
    queued: [Todo]
    active: [In Progress]
    review: [Human Review]
    merge: [Merging]
    rework: [Rework]
    terminal: [Done, Cancelled]
```

Recommended Jira environment variables:

```bash
export JIRA_SITE_URL="https://your-company.atlassian.net"
export JIRA_PROJECT_KEY="ENG"
export JIRA_EMAIL="you@company.com"
export JIRA_API_TOKEN="..."
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- Linear `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is
  `$LINEAR_API_KEY`.
- Jira `tracker.auth.email`, `tracker.auth.api_token`, `tracker.site_url`, and `tracker.project_key`
  can be backed by `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_SITE_URL`, and `JIRA_PROJECT_KEY`.
- `tracker.assignee` is shared across trackers and supports the common `me` shortcut.
- For Jira, `tracker.assignee: me` is the safest default. If you pin Jira to a specific assignee,
  use a Jira account ID instead of a display name so candidate fetch and reconciliation stay aligned.
- `tracker.kind: jira` currently targets Jira Cloud only; Jira Server / Data Center are not supported.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: Linear sample workflow contract
- `WORKFLOW.jira.md`: Jira Cloud sample workflow contract
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
