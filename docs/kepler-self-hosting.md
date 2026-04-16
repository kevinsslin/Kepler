# Kepler Self-Hosting Guide

This is the operator guide for the current `feat/kepler-v1` implementation.

Use this guide together with:

- [`../elixir/README.md`](../elixir/README.md) for build and run commands
- [`./kepler-prd.md`](./kepler-prd.md) for product scope and architecture

## Minimum Successful Deployment

For this branch, the recommended hosted path is now:

- build the repository root [Dockerfile](../Dockerfile)
- deploy that image to Railway
- attach one persistent volume at `/data`
- let the container entrypoint boot Kepler

This is simpler than managing per-platform build/start commands for raw Elixir processes and keeps
Railway, GCP VM, and AWS VM deployments close to the same shape.

Before you debug webhooks, make sure these choices are explicit:

### Linear auth: choose one

- Preferred: `LINEAR_CLIENT_ID` + `LINEAR_CLIENT_SECRET`
- Fallback only: `LINEAR_API_KEY`

### GitHub auth: choose one

- Preferred for Railway/Docker: `GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY_BASE64`
- Also supported: `GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY`
- VM/local fallback: `GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY_PATH`
- Fallback only: `GITHUB_TOKEN`

### Codex runtime: choose one

- Preferred for the bundled fallback workflow: set `CODEX_BIN=codex`
- Alternative: every routed repo provides its own `WORKFLOW.md` with an explicit Codex command

### Observability auth

- If you want `GET /api/v1/kepler/runs`, set `KEPLER_API_TOKEN`
- Without that token, Kepler now leaves the runs endpoint disabled

Important Linear note: `client_credentials` yields an app actor token. According to Linear's OAuth
docs, that token has access to all public teams by default; if you need private-team access, adjust
the app user's team access from the Linear app details page before handing work to Kepler.

## Why Webhooks Are Not Enough

The webhook is only the intake signal. Kepler still needs authenticated Linear API access in order
to:

- fetch full issue context
- request repository suggestions
- post `thought` and `response` activities
- update agent sessions

So the right replacement for a personal `LINEAR_API_KEY` is not “webhook only.” The right
replacement is “webhook for intake, app token for outbound GraphQL.”

Kepler now supports that app-token path through OAuth `client_credentials`.

## Current Runtime Boundary

Kepler v1 is intentionally narrow:

- single process
- single node
- single Linear workspace
- config-backed repository registry
- file-backed durable run state

Do not run multiple replicas behind one Linear webhook in the current implementation.

Other important runtime facts:

- The webhook path is fixed at `/webhooks/linear`.
- Restart recovery reuses the same workspace path but resets the repo to `origin/<default_branch>`.
- `kepler.yml` and env-backed secrets are loaded and cached at boot. Rotate credentials only during
  a controlled restart window.
- `kepler.yml` reads process environment variables only. It does not parse dotenv files by itself,
  so use your process manager's env-file support or source a file such as `.env.kepler` before
  launch.
- For Docker/Railway, you can avoid committing a deployment-specific `kepler.yml` by setting
  `KEPLER_CONFIG_YAML_BASE64` or `KEPLER_CONFIG_YAML`; the shipped entrypoint writes that private
  config to `/data/config/kepler.yml` and points `KEPLER_CONFIG_PATH` at it before Kepler boots.
- GitHub auth is required for every run.
- Codex must already work non-interactively on the host.

## Prerequisites

You need all of the following:

- a public HTTPS hostname for Kepler, for example `https://kepler.example.com`
- one persistent writable volume
- one Linear OAuth app
- one Linear workspace admin who can install the app with `actor=app`
- GitHub auth, preferably through a GitHub App
- the `codex` binary available on the host

## Linear Setup

### 1. Create the Linear OAuth app

Create a new OAuth application in Linear.

Use these settings:

- `actor=app`
- scopes:
  - `read`
  - `write`
  - `app:assignable`
  - `app:mentionable`
- `Client credentials`: enabled
- `Webhooks`: enabled
- webhook category: `Agent session events`

### 2. Fill in the Linear form fields

#### Callback URLs

Set:

```text
https://<your-public-host>/linear/oauth/callback
```

Example:

```text
https://kepler.example.com/linear/oauth/callback
```

Kepler serves this endpoint so the browser redirect has a valid destination. Kepler v1 does not
persist authorization-code installation tokens from that redirect; runtime GraphQL auth comes from
`client_credentials`.

#### GitHub username

Set this to the GitHub identity you want Linear to associate with the app, for example:

```text
kepler[bot]
```

This is a Linear-side display/association field only. It does not configure GitHub runtime auth.

#### Public

Keep this off for Kepler v1. The product scope is single-tenant internal hosting.

#### Client credentials

Turn this on. Kepler uses it to mint app actor tokens for runtime GraphQL calls.

#### Webhook URL

Set:

```text
https://<your-public-host>/webhooks/linear
```

Example:

```text
https://kepler.example.com/webhooks/linear
```

The route is fixed in Kepler v1.

### 3. Install the app into the workspace

After creating the app, have a workspace admin open an authorization URL shaped like this:

```text
https://linear.app/oauth/authorize?client_id=<LINEAR_CLIENT_ID>&redirect_uri=https%3A%2F%2F<your-public-host>%2Flinear%2Foauth%2Fcallback&response_type=code&scope=read,write,app:assignable,app:mentionable&actor=app
```

Notes:

- `actor=app` is what makes the install create an app identity instead of authenticating as a user.
- `app:assignable` and `app:mentionable` are what allow delegation and mentions.
- Kepler v1 does not need the authorization code for runtime GraphQL auth because it uses
  `client_credentials`, but the workspace install is still required so the app exists as a
  delegate-able Linear identity and receives agent session webhooks.

### 4. Capture the webhook secret

Copy the webhook signing secret from Linear and set it as:

```bash
export LINEAR_WEBHOOK_SECRET=...
```

## GitHub Setup

Preferred path: GitHub App.

Minimum useful permissions for the current implementation:

- Repository metadata: read-only
- Repository contents: read and write
- Pull requests: read and write

Fallback path: `GITHUB_TOKEN`

That fallback works, but it has a wider blast radius and is not the preferred long-term identity.

### What Kepler actually uses GitHub for

Kepler does not wait for you to paste a repository URL into each Linear issue.

Instead, you pre-register every allowed repository in `kepler.yml`. For each repository, Kepler
stores:

- `id`
- `full_name`
- `clone_url`
- `default_branch`
- `workflow_path`
- routing selectors such as `labels`, `team_keys`, `project_ids`, or `project_slugs`

At runtime, once routing resolves to one registered repository, Kepler uses the GitHub credentials
already available on the host to:

- clone that repository if the workspace does not exist yet
- synchronize the existing checkout to the configured default branch
- optionally synchronize read-only `reference_repository_ids` into `.kepler/refs/<repo-id>/` for
  code-reading context
- let Codex make changes in that workspace
- push a branch
- open a PR

So the operator flow is:

1. Register the repository in `kepler.yml`.
2. Give the GitHub App or `GITHUB_TOKEN` access to that repository.
3. Let Kepler choose among the registered repositories at runtime.

Kepler does not support arbitrary “tell it a URL in the issue body and let it work there” behavior
in v1.

### Recommended GitHub App setup

Install the GitHub App on every repository that Kepler is allowed to touch.

Best practice:

- keep the installation scope limited to the exact repositories in `kepler.yml`
- use `https://github.com/<org>/<repo>.git` as `clone_url`
- optionally set `github_installation_id` per repo if you want to avoid dynamic installation lookup

For Railway/Docker, do not try to place the downloaded PEM on the container filesystem and point
Kepler at a path. Instead:

1. Generate a private key in the GitHub App settings page.
2. Download the `.pem` file locally.
3. Convert that PEM to base64 on your machine.
4. Store the base64 string in the deployment platform as `GITHUB_APP_PRIVATE_KEY_BASE64`.
5. Keep `kepler.yml` on `github.private_key: $GITHUB_APP_PRIVATE_KEY`.

The shipped container entrypoint already decodes `GITHUB_APP_PRIVATE_KEY_BASE64` into
`GITHUB_APP_PRIVATE_KEY` before Kepler boots.

Example PEM to base64 commands:

macOS:

```bash
base64 -i /absolute/path/to/kepler-github-app.pem | pbcopy
```

Linux:

```bash
base64 -w 0 /absolute/path/to/kepler-github-app.pem
```

If `pbcopy` is not available, remove the pipe and copy the printed output manually. The important
part is that the final secret value is one single base64 line.

If you use `GITHUB_TOKEN` instead:

- the token must be able to clone, push, and open PRs on every registered repository
- the token becomes the effective blast radius for all of Kepler's GitHub operations

### How Git synchronization actually works

Kepler does not run a plain `git pull`.

For an existing workspace checkout, the current implementation does this:

1. `git remote set-url origin <clone_url>`
2. `git fetch origin <default_branch> --prune`
3. `git checkout <default_branch>`
4. `git reset --hard origin/<default_branch>`

For a first-time workspace, it does this:

1. `git clone <clone_url> .`
2. `git checkout <default_branch>`

This means:

- you do not need to pre-clone repos on the host
- you do need valid GitHub credentials on the host
- interrupted local changes are not preserved across restart recovery
- `ssh://...` clone URLs are not the recommended path for v1; use GitHub HTTPS clone URLs

Commits use the configured bot signature from `github.bot_name` and `github.bot_email`.

## Repository Routing Setup

This is the part that decides which Linear issue maps to which repository.

Kepler routes in this exact order:

1. Explicit routing selectors from `kepler.yml`
2. Linear repository suggestions
3. User clarification in the same agent session

### Explicit routing selectors

Each repository registration may declare:

- `labels`
- `team_keys`
- `project_ids`
- `project_slugs`

Current v1 matching semantics are important:

- selectors are matched with OR semantics, not AND semantics
- if any selector family matches, that repository becomes a candidate
- if exactly one repository matches, Kepler chooses it
- if multiple repositories match, Kepler does not guess; it asks the user to choose

Examples:

- If one Linear team maps cleanly to one repo, use `team_keys`.
- If one team owns many repos, prefer distinct `project_slugs` or repo-specific labels.
- If many repos share the same `team_keys`, do not expect `team_keys` alone to route uniquely.
- If one Linear project spans several repos, do not use that shared project as the final routing
  selector. Use a unique repo label instead.

Recommended pattern:

- use one coarse selector for ownership, such as `team_keys` or `project_slugs`
- add repo-specific labels only when you need to split multiple repos inside the same team/project
- keep selector sets non-overlapping whenever possible

Example:

```yaml
repositories:
  - id: "api"
    full_name: "your-org/your-api-repo"
    clone_url: "https://github.com/your-org/your-api-repo.git"
    default_branch: "main"
    workflow_path: "WORKFLOW.md"
    labels: ["api", "backend"]
    team_keys: ["ENG"]
    project_slugs: ["platform-api"]

  - id: "web"
    full_name: "your-org/your-web-repo"
    clone_url: "https://github.com/your-org/your-web-repo.git"
    default_branch: "main"
    workflow_path: "WORKFLOW.md"
    labels: ["web", "frontend"]
    team_keys: ["ENG"]
    project_slugs: ["customer-web"]
    reference_repository_ids: ["api"]
```

In that example:

- an issue in project `platform-api` routes to `api`
- an issue in project `customer-web` routes to `web`
- an issue with label `frontend` routes to `web`
- when `web` is selected, `api` is also available read-only at `.kepler/refs/api/`
- an issue that matches both repos stays ambiguous and Kepler asks the user

### Linear repository suggestions

If explicit selectors do not produce one unique match, Kepler asks Linear for repository suggestions
from the set of registered repositories.

Important boundary:

- Linear suggestions only help choose among repositories already listed in `kepler.yml`
- Kepler does not broaden access to unregistered repos

### User clarification

If the result is still ambiguous, Kepler sends an elicitation back to the same Linear agent session.

The user must reply with one of:

- the configured repository `id`, or
- the configured GitHub `full_name`

Best practice:

- keep repository `id` short and human-readable, such as `api`, `web`, `mobile`
- make sure operators and teammates know those ids

### Current v1 limitation

Concurrency is still scheduled per Linear agent session, but Kepler now rejects a second active
session for the same Linear issue while an existing non-terminal run is in flight. Keep follow-up
prompts on the same session whenever possible.

## Codex Setup

Kepler launches whatever command resolves from the repository workflow or fallback template.

The bundled fallback command is:

```text
$CODEX_BIN --config model_reasoning_effort=high --model gpt-5.4 app-server
```

So either:

- set `CODEX_BIN=codex`, or
- override `codex.command` in the repo-local `WORKFLOW.md`

### Shared fallback workflow

The bundled fallback template at
[`../elixir/priv/templates/WORKFLOW.kepler.template.md`](../elixir/priv/templates/WORKFLOW.kepler.template.md)
is intended to be a real org-wide default, not just a placeholder.

It assumes hosted Kepler behavior and requires the agent to:

- stay inside the already-routed repository
- create or reuse one stable issue branch before editing
- discover and run the highest-signal repo-native validation
- require real automated tests for backend and smart-contract changes
- require screenshot evidence for user-visible frontend changes
- commit and push the issue branch before declaring success
- reuse the same branch on follow-up runs so Kepler updates one PR instead of creating duplicates

It also asks the agent to write `.kepler/pr-report.json` in the workspace when it changes files.
Kepler reads that report and turns it into the PR body. This is not advisory anymore: changed-file
runs are expected to produce a valid structured report, and PR publication now fails if the report
is missing or invalid.

It also asks the agent to keep a local `.kepler/workpad.md` scratchpad in the workspace. This is
the hosted adaptation of the longer local workflow's persistent Linear workpad comment: the agent
keeps plan, acceptance criteria, validation notes, and blockers there across follow-up runs.

Current boundary:

- The report is expected to include `change_type`, structured `validation` entries, summary
  bullets, and optional risks.
- For backend and smart-contract changes, the report must include at least one passing validation
  entry whose `kind` is `test`, `integration`, `e2e`, or `contract`.
- Kepler can render screenshot evidence in the PR body when the report provides screenshot paths.
- Kepler can also render explicit `before_url` / `after_url` fields from the report when you
  already have stable hosted artifact URLs.
- Kepler does not have a separate media upload service in v1.
- If you want screenshots to render inside the PR body today, the workflow must provide paths that
  remain accessible on the issue branch, for example `.kepler/evidence/...` committed on that
  branch, committed into `HEAD`, and pushed to the remote issue branch before PR publication, or
  the report must provide stable hosted URLs instead.
- Do not promise screenshot-backed frontend review if your repos or runtime do not have a workable
  screenshot generation path yet.

Kepler also links the PR back into Linear without relying on Linear branch-name matching:

- it updates the active agent session `externalUrls`
- it creates an issue attachment for the PR URL through Linear's attachment API
- it includes the Linear issue URL in the generated PR body so GitHub reviewers can navigate back to the ticket

These backlink writes are best-effort. If Linear rejects the session update or attachment write,
Kepler logs the failure but does not fail the whole run retroactively.

Repo-local override precedence is unchanged:

1. If `repository.workflow_path` exists inside the repo, Kepler loads that file.
2. Otherwise, Kepler loads `routing.fallback_workflow_path`.

For teams where most repos should behave the same way, the simplest pattern is:

- keep `routing.fallback_workflow_path` pointed at the bundled template
- omit repo-local `WORKFLOW.md` files at first
- add a repo-local override only when one repo truly needs different behavior
- when you add an override, keep the hosted handoff contract intact: the override must still write a
  valid `.kepler/pr-report.json` for any run that changes files or refreshes an existing PR, or
  Kepler will fail PR publication by design

This intentionally differs from the local Symphony polling workflow in [`../elixir/WORKFLOW.md`](../elixir/WORKFLOW.md):

- the local workflow encodes a tracker-driven state machine
- Kepler hosted mode is driven by Linear agent sessions, not tracker polling
- so the shared fallback borrows the execution discipline from the longer example, but it does not
  copy the `Todo/Rework/Human Review/Merging` state machine into hosted runs

Verify before deployment:

```bash
codex app-server --help
```

For containerized deploys, this branch now ships an entrypoint that can do the non-interactive
Codex login step for you on boot:

```text
printenv OPENAI_API_KEY | codex login --with-api-key
```

So the practical production requirement is:

- `OPENAI_API_KEY` must be present on the host/container whenever `CODEX_BIN=codex`

## Environment Variables

Recommended production variables:

| Variable | Required | Purpose |
| --- | --- | --- |
| `LINEAR_CLIENT_ID` | Yes | Preferred Linear runtime auth path. |
| `LINEAR_CLIENT_SECRET` | Yes | Preferred Linear runtime auth path. |
| `LINEAR_WEBHOOK_SECRET` | Yes | Verifies `Linear-Signature`. |
| `LINEAR_API_KEY` | No | Fallback Linear runtime auth only. |
| `KEPLER_WORKSPACE_ROOT` | Yes | Persistent workspace root. |
| `KEPLER_STATE_ROOT` | Yes | Persistent state root. |
| `KEPLER_API_TOKEN` | No, but recommended | Enables and protects `GET /api/v1/kepler/runs`. |
| `CODEX_BIN` | Required if the fallback workflow is used unchanged | Codex executable for the bundled shared workflow. |
| `OPENAI_API_KEY` | Yes for the shipped Docker/Railway deployment | Non-interactive Codex login at container startup. |
| `GITHUB_APP_ID` | Yes, unless `GITHUB_TOKEN` is used | GitHub App auth path. |
| `GITHUB_APP_PRIVATE_KEY_BASE64` | Yes for the recommended Railway/Docker path, unless `GITHUB_TOKEN` is used | Preferred GitHub App key secret for container platforms; decoded into `GITHUB_APP_PRIVATE_KEY` by the shipped entrypoint. |
| `GITHUB_APP_PRIVATE_KEY` | Yes, unless `GITHUB_TOKEN`, `GITHUB_APP_PRIVATE_KEY_BASE64`, or `private_key_path` is used | Inline GitHub App private key. |
| `GITHUB_APP_PRIVATE_KEY_PATH` | VM/local fallback only | Filesystem path to a PEM file on hosts where you control a stable path. |
| `GITHUB_TOKEN` | Optional fallback | Fallback GitHub runtime auth. |

## `kepler.yml` Guidance

Start from [`../elixir/templates/kepler.yml.example`](../elixir/templates/kepler.yml.example).

For Linear, the recommended block now looks like:

```yaml
linear:
  endpoint: "https://api.linear.app/graphql"
  client_id: $LINEAR_CLIENT_ID
  client_secret: $LINEAR_CLIENT_SECRET
  oauth_token_url: "https://api.linear.app/oauth/token"
  oauth_scopes: ["read", "write", "app:assignable", "app:mentionable"]
  webhook_secret: $LINEAR_WEBHOOK_SECRET
```

Use `linear.api_key` only if you intentionally want the fallback path.

For each repository, fill in:

- `id`
- `full_name`
- `clone_url`
- `default_branch`
- `workflow_path`

If you want a single shared workflow across many repos, leave `workflow_path` as `WORKFLOW.md` but
do not create that file in the repos yet. Kepler will fall back to the bundled template until a
repo later adds its own override.
- routing selectors such as `labels`, `team_keys`, `project_ids`, or `project_slugs`

Use HTTPS GitHub clone URLs unless you have a strong reason not to.

## Start the Service

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony kepler \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --config ./kepler.yml
```

Useful endpoints:

- `GET /api/v1/kepler/health`
- `GET /api/v1/kepler/runs`
- `GET /linear/oauth/callback`
- `POST /webhooks/linear`

Operational boundary:

- `POST /webhooks/linear` must be reachable from Linear over public HTTPS
- `GET /api/v1/kepler/runs` should not be left open on the public internet
- prefer to put the observability endpoints behind a private network, VPN, or reverse-proxy auth

## Smoke Test

1. Confirm `GET /api/v1/kepler/health` returns `200`.
2. Delegate a test issue to the Kepler app in Linear.
3. Confirm Linear receives an acknowledgement activity quickly.
4. Confirm the run appears in `GET /api/v1/kepler/runs`.
5. Confirm Kepler creates or refreshes the expected workspace.
6. Confirm Kepler opens a PR or reports a visible failure into the same agent session.

## Failure Modes

- Missing or wrong `LINEAR_WEBHOOK_SECRET`: webhook requests fail with `401`.
- Missing Linear runtime auth:
  - if neither client credentials nor API key are configured, Kepler fails at boot
  - if `client_credentials` is enabled in config but disabled in Linear, token minting fails at runtime
- Webhook payload invalid: returns `400`.
- Control plane unavailable during intake: returns `503` so Linear can retry.
- Wrong routing rules: the session stays in repository elicitation until the user clarifies.
- Wrong or overlapping routing rules: the session stays in repository elicitation until the user
  clarifies.
- Missing GitHub repo access: clone, push, or PR creation fails even if routing succeeded.
- Restart during execution: Kepler later retries from a fresh synchronized checkout of the default branch.

## Railway Notes

Railway is a reasonable v1 target if you keep the deployment narrow:

- one service instance
- one persistent volume
- stable public HTTPS URL
- all secrets in Railway environment variables

Do not scale Kepler horizontally in the current implementation.

The repository now includes a Railway-ready deployment path:

- [../Dockerfile](../Dockerfile)
- [../railway.toml](../railway.toml)
- [../elixir/scripts/docker-entrypoint.sh](../elixir/scripts/docker-entrypoint.sh)
- [../elixir/kepler.yml](../elixir/kepler.yml)

Recommended Railway operator steps:

1. Create a Railway service from this repository.
2. Keep the default root at the repository root so Railway picks up `Dockerfile` and `railway.toml`.
3. Attach one volume at `/data`.
4. Set secrets:
   - `OPENAI_API_KEY`
   - `LINEAR_WEBHOOK_SECRET`
   - `KEPLER_WORKSPACE_ROOT=/data/workspaces`
   - `KEPLER_STATE_ROOT=/data/state`
   - `KEPLER_API_TOKEN` if you want the runs endpoint
   - Linear auth:
     - preferred: `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET`
     - fallback: `LINEAR_API_KEY`
   - GitHub auth:
     - preferred: `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY_BASE64`
     - fallback: `GITHUB_TOKEN`
5. Generate a Railway public domain.
6. After the service is live, wire that public URL into the Linear app:
   - webhook URL: `https://<domain>/webhooks/linear`
   - callback URL: `https://<domain>/linear/oauth/callback`
7. Smoke test:
   - `GET /api/v1/kepler/health`
   - `GET /api/v1/kepler/runs` with `Authorization: Bearer <KEPLER_API_TOKEN>`
   - delegate one issue that has exactly one `repo:*` routing label

The shipped entrypoint handles:

- ensuring `/data/home`, `/data/workspaces`, and `/data/state` exist
- decoding `GITHUB_APP_PRIVATE_KEY_BASE64`
- authenticating `codex` from `OPENAI_API_KEY` when needed
- starting Kepler on Railway's `$PORT`
