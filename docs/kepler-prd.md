# Kepler Product Requirements Document

## Document Control

- Product name: Kepler
- Base platform: Symphony
- Document type: Product Requirements Document
- Status: Draft for review
- Last updated: 2026-04-12
- Intended audience: product owner, engineering, infra, security reviewers, agent reviewers
- Companion operator guide: [`kepler-self-hosting.md`](./kepler-self-hosting.md)

This PRD defines the product and implementation boundary. It is not the deployment runbook.
Operators should use the companion self-hosting guide for setup and day-2 operations.

## Executive Summary

Kepler is a deployable, single-tenant orchestration service built on top of Symphony. Its purpose is
to let a product engineering team delegate Linear issues to an agent that can select the correct
repository, create or reuse an isolated workspace, run a coding agent in the cloud, and report its
progress back into Linear and GitHub using a clearly identifiable agent identity.

The current Symphony proof of concept works well as a trusted local setup, but it is still shaped
around a local operator model: a local machine, local clones, locally provisioned auth, and a
single repository workflow. Kepler turns that proof of concept into an operable service with a
clear deployment model, identity model, routing model, and recovery model.

Kepler v1 is intentionally narrow. It is an internal, single-tenant service for one organization.
It supports one Linear workspace, many repositories, one production agent provider at launch
(Codex), and a delegated-agent interaction model in Linear. It is not a multi-tenant SaaS product
and it does not attempt to solve every workflow or policy problem in v1.

## Background

Symphony already provides a strong execution core:

- It polls or reads tracker work.
- It creates per-issue workspaces.
- It launches Codex in app-server mode inside those workspaces.
- It uses repository-owned `WORKFLOW.md` files to define runtime policy and prompts.
- It can already run workspaces remotely through SSH-backed workers.

This is enough to validate the execution concept locally, but it leaves several product gaps
unaddressed:

1. Repository selection is still effectively manual or repo-scoped.
2. Identity is not productized. The current flow depends on operator-managed local credentials.
3. The system does not yet expose a deployable control plane for cloud operation.
4. There is no durable run registry suitable for restart recovery, auditability, or hosted ops.
5. The current user experience is not aligned with Linear's native agent model.

The desired end state is an agent that behaves like a real teammate in the tools where work already
lives:

- It is visible in Linear as a distinct agent identity.
- It can be delegated issues by humans without replacing human ownership.
- It can determine which repository the issue belongs to.
- It can open branches, comments, and pull requests on GitHub as a distinct service identity.
- It can survive restarts and deployments without losing track of active work.

## Problem Statement

Product engineering teams want to delegate implementation work to an autonomous coding agent, but
today the operating model is still too local and too manual. The current proof of concept requires a
trusted operator environment with source repositories and auth material prepared on a local machine.
That setup is powerful for experimentation but weak for team adoption, governance, and repeatable
operations.

The main problems are:

- A delegated issue may belong to any of several repositories in the same Linear workspace.
- The execution runtime should not depend on a developer laptop remaining online and configured.
- The agent must have a first-class, non-human identity in Linear and GitHub.
- The service must recover cleanly from restarts, redeploys, and transient infrastructure failures.
- Authentication must be non-interactive and safe for server-side deployment.

## Vision

Kepler should make agent execution feel like a native extension of an engineering team's existing
workflow:

- A human delegates a Linear issue to Kepler.
- Kepler immediately acknowledges the task in Linear.
- Kepler chooses the correct repository or asks for clarification when routing is ambiguous.
- Kepler runs the task in an isolated cloud workspace using a repository-defined workflow.
- Kepler pushes code and opens a pull request using a distinct GitHub identity.
- Kepler updates the Linear session with progress, evidence, and final results.

## Goals

### Primary goals

- Turn Symphony into a deployable internal service rather than a local-only proof of concept.
- Support one Linear workspace that spans many repositories.
- Use Linear's native agent model so Kepler appears as a real delegated agent.
- Use a distinct GitHub service identity for repository access, pull requests, and comments.
- Preserve Symphony's repository-owned workflow model instead of centralizing all task policy.
- Introduce durable persistence for run metadata, routing decisions, and recovery state.
- Keep v1 operationally simple enough to run on Railway.

### Secondary goals

- Preserve compatibility with existing Symphony execution concepts where practical.
- Keep the execution boundary clean enough that future providers can be added later without
  redesigning the whole service.
- Allow future migration from colocated workers to remote workers without redesigning the product.

## Non-Goals

Kepler v1 will not do the following:

- Multi-tenant SaaS for unrelated customers or workspaces.
- Fully generic workflow orchestration across arbitrary external systems.
- Browser-based or human-in-the-loop login flows to `claude.ai`, ChatGPT, GitHub, or Linear.
- A true "agent is the assignee" ownership model in Linear.
- A rich self-serve admin console for non-technical operators.
- Full remote worker fleet orchestration on day one.
- General cloud portability across every platform in v1.
- Complete elimination of repository-local configuration.

## Product Principles

### 1. Use native platform identities where possible

Kepler should behave like a first-class app in Linear and GitHub, not a disguised human account.

### 2. Keep execution policy close to code

Repository-specific prompts, commands, and workflow policy should remain repository-owned by
default through `WORKFLOW.md`.

### 3. Never guess the repository when routing is ambiguous

Wrong-repository execution is a high-cost failure mode. Kepler must route conservatively.

### 4. Cloud deployment must not degrade auditability

Moving execution into the cloud should improve, not reduce, traceability of what happened.

### 5. Build a narrow v1 that can actually operate

A smaller system with clear identity, routing, persistence, and recovery is preferable to a broad
system that is operationally fragile.

## Users and Stakeholders

### Primary user

- Product engineers or tech leads who delegate implementation work from Linear.

### Secondary users

- Reviewers who inspect pull requests and execution summaries.
- Infra or platform engineers who operate Kepler.
- Security reviewers who evaluate permissions and auditability.

### System stakeholders

- Linear workspace admins
- GitHub organization admins
- Repository maintainers
- Team leads responsible for workflow quality

## Scope of v1

### In scope

- One deployed Kepler service per organization.
- One Linear workspace installation.
- Multiple GitHub repositories in the same organization or trusted set.
- Linear delegated-agent flow using app installation and webhooks.
- Repository routing based on explicit rules, Linear repository suggestions, and user elicitation.
- Codex as the only production execution provider.
- GitHub App-based identity for repository access and PR operations.
- Railway deployment with a persistent volume and file-backed durable state.
- Durable run metadata and restart recovery.
- Repository-local `WORKFLOW.md` with a central fallback template.

### Out of scope

- Multi-workspace tenancy
- Billing and customer isolation
- End-user UI beyond Linear/GitHub surfaces and minimal service observability
- Claude as a production execution backend
- Dedicated Gmail-based runtime identity as a primary auth mechanism

## Core Use Cases

### Use case 1: Delegate a repo-specific bug fix

1. A human delegates a Linear issue to Kepler.
2. Kepler receives the Agent Session webhook.
3. Kepler resolves the correct repository uniquely.
4. Kepler provisions a workspace, loads the repository workflow, and starts a run.
5. Kepler posts progress activities in Linear.
6. Kepler pushes a branch and opens a PR as its GitHub App identity.
7. Kepler marks the run complete or error with a clear summary.

### Use case 2: Ambiguous repository assignment

1. A human delegates a Linear issue whose repository cannot be determined uniquely.
2. Kepler evaluates explicit routing rules and Linear repository suggestions.
3. Routing remains ambiguous.
4. Kepler sends an elicitation back to the user with a small set of candidate repositories.
5. Kepler waits for user input before starting execution.

### Use case 3: Service restart during an active run

1. Kepler is running an active task.
2. Railway restarts or redeploys the service.
3. Kepler boots, loads persisted run metadata, and marks any in-flight run as `interrupted`.
4. Kepler decides whether the run can be requeued.
5. If requeued, Kepler starts a fresh Codex process after synchronizing the repository checkout back
   to the configured default branch.
6. Kepler posts a visible explanation in the Linear session instead of silently pretending the
   provider process survived the restart.

## User Experience Requirements

### Linear experience

- Kepler must appear as a distinct agent/app identity in Linear.
- Delegating to Kepler must create a visible Agent Session in Linear.
- Kepler must acknowledge new work quickly with a `thought` activity.
- Kepler must keep session state current using agent activities.
- Kepler must surface repo ambiguity as a clear user choice rather than silent failure.
- Kepler must attach or update PR links in the Linear session when work is published.
- Kepler must also create or update a Linear issue attachment for the PR URL so issue-to-PR linkage
  does not depend on Linear branch-name matching.
- Kepler must include the Linear issue URL in the generated PR body so PR reviewers can navigate
  back to the originating ticket without relying on branch naming conventions.

### GitHub experience

- Pull requests, issue comments, and status updates must clearly come from Kepler's GitHub App
  identity, not from a human developer.
- Commit author and committer metadata must use a fixed, recognizable Kepler bot signature.
- Repository access must be limited to installations and scopes explicitly granted to Kepler.

## Functional Requirements

### 1. Control Plane

Kepler must introduce a control plane around Symphony's existing execution core.

Requirements:

- The system must no longer assume one process maps to one repository.
- The system must manage a registry of repositories and routing rules.
- The system must persist run metadata outside process memory.
- The system must coordinate intake, routing, execution, and reconciliation.

### 2. Intake Model

Kepler v1 must use Linear's agent interaction model as its primary intake path.

Requirements:

- Kepler must install into a Linear workspace using `actor=app`.
- Kepler must require the Linear agent scopes `app:assignable` and `app:mentionable` for the
  hosted delegated-agent flow described in this document.
- Kepler must subscribe to agent session webhook events.
- Kepler must create a run in response to delegated agent sessions.
- Kepler must respond within platform timing expectations by acknowledging work quickly.
- Kepler must support follow-up prompts or user replies on the same session.
- Runtime GraphQL reads and writes must use server-safe app credentials rather than a human-owned
  personal token by default.
- In v1, the preferred runtime auth path is OAuth `client_credentials` using the Linear app's
  `client_id` and `client_secret`.
- `linear.api_key` may remain as an explicit fallback path for staging or migration, but it is not
  the recommended production path.

### 3. Repository Registry

Kepler must maintain a durable registry of repositories it is allowed to operate on.

Each repository registration must include:

- Stable repository ID
- GitHub repository full name
- Clone URL
- Default branch
- Expected `WORKFLOW.md` path
- Routing selectors
- Allowed teams or projects
- GitHub installation metadata

In v1, the repository registry must be configuration-backed. The source of truth is
`KeplerConfig.repositories[]`, loaded at boot and validated before the service begins processing
work. Runtime mutation through a UI or database editor is out of scope for v1.

### 4. Repository Routing

Kepler must select a repository using a deterministic order of operations:

1. Explicit routing rules
2. Linear repository suggestions
3. User elicitation

Requirements:

- Explicit routing rules may match on team, project, label, or other configured selectors.
- Current `feat/kepler-v1` note: explicit selector matching is OR-based across
  `labels|team_keys|project_ids|project_slugs`. A repo becomes a routing candidate if any selector
  family matches.
- Operators should prefer non-overlapping selector sets. If several repositories share the same
  team or label selectors, ambiguity is the expected result rather than a bug.
- Linear repository suggestions must be evaluated when explicit rules do not yield a unique match.
- Routing outcomes must be explicit: `resolved` or `ambiguous`.
- A resolved routing decision must record the winning repository and the deciding source on the run
  record.
- An ambiguous routing result must record the candidate repositories in structured logs and must not
  start execution until the user chooses a repository.
- Kepler must not accept arbitrary repository URLs from issue text or session prompts. Routing is
  restricted to the pre-registered repository allowlist in `KeplerConfig.repositories[]`.

### 5. Workflow Resolution

Kepler must continue to prefer repository-local workflow policy.

Requirements:

- For a resolved repository, Kepler must attempt to load the repository's `WORKFLOW.md`.
- If the repository does not provide one, Kepler must load a central fallback template.
- The fallback template must be strong enough to serve as a shared org default when most repos do
  not need custom policy.
- At minimum, the fallback template must require a stable issue branch, repo-native validation,
  commit/push before success, and branch reuse on follow-up runs so one issue converges on one PR.
- For user-visible frontend changes, the fallback template must require screenshot evidence.
- For backend and smart-contract changes, the fallback template must require relevant automated
  tests rather than lint-only success.
- The hosted fallback may borrow execution discipline from the longer local `WORKFLOW.md`, but it
  must not pretend to implement the local tracker/polling state machine when hosted Kepler is
  session-driven.
- Repository-owned workflow files remain the first-class override mechanism for repo-specific
  policy.
- Any repo-local override must preserve the hosted PR handoff contract by emitting a valid
  `.kepler/pr-report.json` for changed-file runs and existing-PR refresh runs; Kepler does not
  provide a legacy publication fallback once an override is in control.
- Workflow selection must be recorded on the run record.

### 5.1 Pull Request Handoff Contract

Kepler must have a machine-readable path for turning run evidence into a PR description.

Requirements:

- When a workflow changes files, or when it refreshes an existing issue-branch PR, it must emit a
  structured PR handoff report in the workspace.
- The GitHub publish path must require that structured report rather than silently falling back to
  a placeholder body.
- The report format must support:
  - explicit `change_type`
  - whether tests are required
  - summary bullets
  - structured validation evidence with command, kind, and result
  - optional frontend before/after screenshot references
  - optional hosted frontend evidence URLs
  - blocker declarations
  - optional residual risks
- Frontend evidence must be either stable hosted URLs or relative paths that exist in the
  workspace, are committed into `HEAD`, and are present on the pushed remote issue branch so
  GitHub can render them from the PR.
- Backend and smart-contract changes must include at least one passing automated test entry in the
  structured validation evidence.

### 6. Execution Backend

Kepler v1 must execute work through Codex using Symphony's existing app-server execution path.

Requirements:

- `CodexRunner` must wrap the existing Symphony Codex app-server execution path.
- v1 must not promise provider-level process resume after host restart.
- If the service restarts mid-run, the provider process is treated as lost and the run must be
  requeued or failed according to the recovery rules below.
- No runtime authentication path may require browser-based human login.
- Future provider support is explicitly deferred until v1 proves out the hosted Codex path.
- Current `feat/kepler-v1` note: the bundled fallback workflow expects `$CODEX_BIN app-server ...`.
  Operators must set `CODEX_BIN=codex` or provide a repo-local workflow with an explicit
  `codex.command`.

### 7. Workspace Lifecycle

Kepler must preserve Symphony's isolated workspace model.

Requirements:

- One workspace per active issue run
- Workspace path recorded in persistence
- Workspaces stored on a persistent Railway volume
- Fresh clone on first run, reuse of the same workspace path on requeue when safe
- Current `feat/kepler-v1` note: repository synchronization is done by `fetch + checkout +
  reset --hard origin/<default_branch>`, not by `git pull`.
- Current `feat/kepler-v1` note: workspace directories are reused and are not yet automatically
  pruned after terminal runs. Operators must provision enough volume and apply their own cleanup
  policy outside the running service if needed.

### 8. Run Lifecycle and Concurrency

Kepler must define a small, explicit run state machine so hosted operation and restart recovery are
implementable without guesswork.

The current `feat/kepler-v1` operational lifecycle is:

- `awaiting_repository_choice`: waiting on user clarification
- `queued`: repository resolved and waiting for a worker slot
- `executing`: Codex app-server process is running
- `completed`: terminal success
- `failed`: terminal failure
- `interrupted`: host or process died while the run was non-terminal

Other statuses such as `pending`, `preparing_workspace`, `publishing`, or `cancelled` should be
treated as reserved vocabulary, not stable operational states for the current implementation.

Requirements:

- v1 must allow at most one active run per `linear_agent_session_id`.
- v1 must reject a second active agent session for the same `linear_issue_id` while an existing
  non-terminal run is still active.
- v1 must expose `limits.max_concurrent_runs`; the recommended default is `2`.
- When all execution slots are full, additional resolved runs must remain in `queued` rather than
  starting opportunistically.
- In the current implementation, webhook handling and recovery are serialized through a single
  control-plane GenServer on one node. Multi-node coordination is out of scope for v1.
- A run in `executing` that loses its provider process must transition to
  `interrupted` before any recovery action is taken.

### 9. Persistence and Recovery

Kepler must add durable state suitable for hosted operation.

Persistence must include:

- Run records
- Routing source and chosen repository on each run
- Workspace path references
- PR links and branch metadata
- Error history

Requirements:

- Persistent state must live on the attached service volume as an authoritative JSON state file in v1.
- Current `feat/kepler-v1` note: the persisted JSON state is a bounded operational record, not an
  infinite archive. Kepler retains all non-terminal runs plus only a recent window of terminal runs
  (default retention: 200) in durable state.
- Kepler must reconcile active runs on startup.
- v1 recovery must not attempt to reattach to a dead provider subprocess.
- On startup, any run left in `preparing_workspace`, `executing`, or `publishing` must transition to
  `interrupted`.
- An interrupted run may be requeued only if repository routing is still resolved and Kepler still
  has enough metadata to reconstruct the run safely.
- Requeue means starting a new Codex process from the persisted run record. It does not mean
  reviving in-memory provider state.
- Current `feat/kepler-v1` note: a recovered run reuses the same workspace path, but before
  execution Kepler checks out the configured default branch and hard-resets to
  `origin/<default_branch>`. Uncommitted changes from the interrupted process are not preserved.
- If recovery cannot establish a safe requeue path, the run must transition to `failed` with a
  visible explanation in the Linear session and persistent error state.

### 10. Identity and Authentication

Kepler must use app-based or server-safe auth wherever possible.

Requirements:

- Linear intake identity must come from the installed Linear app.
- Runtime Linear GraphQL calls should use OAuth app tokens minted through `client_credentials`.
- The service must tolerate token expiry or invalidation by minting a fresh app token when Linear
  returns `401`.
- Kepler v1 does not need to persist authorization-code installation tokens in order to operate as
  a single-tenant hosted service.
- `linear.api_key` may remain as a fallback path, but it should be treated as a temporary operator
  convenience rather than the target identity model.
- GitHub authentication should use GitHub App installation tokens.
- Current `feat/kepler-v1` note: the runtime also accepts a host-level `GITHUB_TOKEN` fallback.
- Current `feat/kepler-v1` note: `kepler.yml` and env-backed credentials are loaded and cached at
  boot. Rotating secrets or changing auth/config requires a service restart before the runtime sees
  the new values.
- Kepler must not impersonate a human GitHub user for commits or PRs.
- Secrets must be injected through Railway environment variables or equivalent secret storage.
- v1 must not depend on Gmail login or Google SSO for core runtime execution.

### 11. GitHub Operations

Kepler must be able to perform repository operations as a service identity.

Requirements:

- Clone the repository with GitHub App-backed credentials or a functionally equivalent repo-scoped
  access method such as a host-level `GITHUB_TOKEN`.
- Kepler must derive clone/publish targets from the pre-registered repository registry, not from
  arbitrary URLs supplied at task time.
- Create branches from the configured base branch.
- Push code changes.
- Open or update pull requests.
- Update pull request metadata and body when required.
- Record GitHub installation ID and PR URL in persistent run state.
- Current `feat/kepler-v1` note: GitHub App installation tokens are minted when GitHub operations
  run, but the app credentials used to mint them are still the boot-loaded credentials. Credential
  rotation therefore requires a controlled restart, and a restart interrupts any active run.
- Current `feat/kepler-v1` note: the recommended operator path is HTTPS GitHub clone URLs plus
  GitHub App or `GITHUB_TOKEN` auth; `ssh://` clone URLs are not the intended path for v1.

### 12. Observability

Kepler must expose enough observability to operate the service in production.

Requirements:

- Structured logs for intake, routing, execution, recovery, and publish steps
- A run-level audit trail
- Health checks for service readiness and dependency checks
- Visibility into currently active, queued, errored, and completed runs
- Traceable links between Linear issue ID, Linear agent session ID, workspace path, repository,
  branch, PR, and run status
- Current `feat/kepler-v1` note: only the Linear webhook must be publicly reachable. The
  observability endpoints should be protected by network controls or reverse-proxy auth in a real
  deployment.

### 13. Deployment

Kepler v1 must target Railway.

Requirements:

- One persistent service process
- Configurable `limits.max_concurrent_runs` with queueing when saturated
- Attached volume for workspaces and logs
- File-backed durable state rooted under `state.root`
- Environment-based configuration and secrets
- Public HTTPS ingress for the fixed Linear webhook path `/webhooks/linear`
- Support for restarts and redeploys without assuming replica availability
- Current `feat/kepler-v1` note: the HTTP router serves the Linear webhook at the fixed path
  `/webhooks/linear`; the runtime does not expose a configurable webhook path.

### 14. Failure Handling

Kepler must fail in ways that are visible and actionable.

Requirements:

- Missing auth must fail visibly with a clear operational error.
- Current `feat/kepler-v1` note: some auth failures surface at boot, while others surface on first
  use. Operator docs must call out both cases explicitly.
- Ambiguous repo routing must result in user elicitation, not blind execution.
- Publish failures must be reflected in both persistent state and user-visible status.
- Recovery failures must not silently drop active work.
- Current `feat/kepler-v1` note: webhook intake is considered successful only after the control
  plane accepts the payload synchronously. Intake returns `200` on success and a retryable `5xx`
  when the control plane is unavailable.

## Non-Functional Requirements

### Security

- Scope all third-party permissions to the minimum needed for v1.
- Avoid long-lived user tokens when app tokens are available.
- Keep secrets out of repository configuration and logs.

### Reliability

- The service must tolerate restarts without losing authoritative knowledge of active runs.
- The service must degrade predictably when external dependencies are unavailable.

### Auditability

- Every run must have a durable identity and traceable decision history.
- Every external side effect should be attributable to the Kepler service identity.

### Extensibility

- The architecture must allow additional providers and remote workers later, but v1 must not force
  abstractions that are only justified by those future modes.
- The repository registry must be general enough to support additional routing signals over time.

## System Design Summary

Kepler v1 consists of the following logical layers:

### Intake layer

- Linear app installation
- OAuth `client_credentials` token minting for runtime GraphQL access
- Agent session webhooks
- Session acknowledgment and activity publishing

### Control layer

- Run creation
- Repository routing
- Workflow resolution
- Persistence
- Recovery

### Execution layer

- Workspace provisioning
- Codex runner
- Symphony runner reuse
- Git publish flow

### Integration layer

- Linear GraphQL and webhook APIs
- GitHub App APIs and Git transport
- Railway runtime services

## Data Model

### KeplerConfig

Fields:

- `service_name`
- `server.host`
- `server.port`
- `server.api_token` (optional)
- `linear.endpoint`
- `linear.client_id` / `linear.client_secret` or `linear.api_key`
- `linear.oauth_token_url`
- `linear.oauth_scopes`
- `linear.webhook_secret`
- `repositories[]`
- `workspace.root`
- `state.root`
- `state.file_name`
- `limits.max_concurrent_runs`
- `limits.dispatch_interval_ms`
- `routing.fallback_workflow_path`
- `routing.ambiguous_choice_limit`

### RepositoryRegistration

Fields:

- `id`
- `full_name`
- `clone_url`
- `default_branch`
- `workflow_path`
- `provider`
- `github_installation_id`
- `labels`
- `team_keys`
- `project_ids`
- `project_slugs`

### RoutingDecision

Fields:

- `repository_id`
- `source`
- `reason`
- `candidate_repositories`

### RunRecord

Fields:

- `id`
- `linear_issue_id`
- `linear_issue_identifier`
- `linear_agent_session_id`
- `repository_id`
- `workspace_path`
- `github_installation_id`
- `branch`
- `pr_url`
- `status`
- `routing_source`
- `routing_reason`
- `repository_candidates`
- `prompt_context`
- `last_error`
- `created_at`
- `updated_at`

## Deployment Architecture

### Railway in v1

Railway is the preferred deployment target because it matches the operational shape of Kepler v1:

- A long-running service
- Persistent volume support for workspaces
- File-backed state on the attached volume
- Straightforward secret injection
- Low operational overhead for an internal service

### Why not Cloudflare Workers in v1

Cloudflare Workers are not the right fit for the initial implementation because Kepler requires a
process-oriented execution model with local workspaces, Git operations, provider subprocess
integration, and restart-aware local state. Those constraints fit Railway more naturally than the
standard Workers model.

## Security and Trust Model

Kepler is a high-trust internal automation service. v1 assumes:

- Trusted repositories
- Trusted workspace admins
- Controlled GitHub installations
- Server-side secrets managed by the operator

Security expectations:

- Kepler may execute repository-defined workflow hooks, so repository trust is required.
- The system must not automatically broaden repo access beyond registered repositories.
- App identities must be clearly distinguishable from human users.
- Logs must not leak tokens or secrets.

## Success Metrics

### Product success

- Time from Linear delegation to first agent acknowledgment
- Percentage of delegated issues successfully routed without manual intervention
- Percentage of delegated issues that reach PR creation
- Percentage of runs that recover correctly after restart or redeploy

### Operational success

- Restart recovery success rate
- Mean time to diagnose failed runs
- Rate of wrong-repository routing incidents
- Rate of authentication-related failures

### User trust signals

- Reviewer acceptance rate of agent-created PRs
- Frequency of manual rerouting or correction
- Number of issues delegated repeatedly after successful prior runs

## Release Criteria for v1

Kepler v1 is considered ready when all of the following are true:

- A delegated Linear issue can create a visible Kepler run.
- Kepler can route across multiple repositories with deterministic behavior.
- Kepler queues work deterministically once all execution slots are occupied.
- Kepler can clone, execute, and publish a PR for at least one repository end to end.
- Kepler uses a distinct, non-human GitHub identity.
- Run metadata persists across service restart.
- A staging redeploy during an active run produces a safe and explainable `interrupted -> queued` or
  `interrupted -> failed` outcome.

## Test Strategy

### Phase 1 release gates

#### Routing gates

- An issue is routed by explicit rule to the correct repository.
- An issue is routed by Linear repository suggestion when explicit rules do not decide.
- An ambiguous issue triggers elicitation instead of execution.

#### Identity gates

- Delegation in Linear creates an Agent Session for Kepler.
- GitHub PRs and comments are authored by the GitHub App identity.
- Git commits use the fixed Kepler bot signature.

#### Concurrency and recovery gates

- A second webhook for the same `linear_agent_session_id` does not create a duplicate active run.
- Work beyond `limits.max_concurrent_runs` is queued rather than started immediately.
- Restart with an active run transitions safely through `interrupted` and then either requeues or
  fails visibly.
- Revoked tokens produce visible fail-fast behavior.

#### End-to-end gates

- Delegate issue in Linear
- Resolve repository
- Clone repository
- Run Codex-backed workflow
- Push branch
- Open PR
- Report progress and outcome back into Linear

### Phase 2 hardening

#### Infrastructure hardening

- Railway volume is mounted and reused across deploys
- State file loads cleanly on cold boot and interrupted runs are reconciled
- Service health checks fail closed when required dependencies are unavailable

## Rollout Plan

### Phase 0: Foundation

- Define PRD and architecture
- Add persistence model and repository registry
- Add explicit run state machine and concurrency limits
- Add Railway deployment configuration

### Phase 1: Internal staging

- Install Kepler into a staging Linear workspace
- Connect to a small set of staging repositories
- Validate routing, execution, publish, and recovery

### Phase 2: Limited production

- Enable Kepler for a small subset of repositories in the production workspace
- Restrict delegation to a small operator group
- Track routing and recovery issues closely

## Risks and Mitigations

### Risk: Wrong repository routing

Impact:

- High. The agent may change the wrong codebase.

Mitigation:

- Prefer explicit rules.
- Use user elicitation when ambiguous.

### Risk: Hosted runtime loses auth or session continuity

Impact:

- High. Active work may stall or publish may fail.

Mitigation:

- Persist run state.
- Reconcile on startup.
- Fail visibly when tokens are invalid.

### Risk: App-based identity is insufficient for a desired workflow

Impact:

- Medium. Some org-specific workflows may still assume a human account.

Mitigation:

- Keep a documented fallback path for a dedicated bot user if a hard requirement emerges later.
- Do not make the human-bot model the default for v1.

### Risk: Railway restarts interrupt long-running tasks

Impact:

- Medium to high depending on task length.

Mitigation:

- Persist authoritative run state on the attached volume.
- Keep workspaces on a volume.
- Test redeploy behavior in staging before widening rollout.

### Risk: Over-customized central workflow erodes repository ownership

Impact:

- Medium. Repositories become harder to reason about locally.

Mitigation:

- Keep repository-local `WORKFLOW.md` as the default.
- Limit the central fallback template to bootstrap and simple repos.

## Deferred Decisions

These topics are intentionally deferred beyond v1:

- Multi-tenant workspace isolation
- Claude as a production backend
- Remote worker fleet and scheduling
- Full operator web UI
- Rich policy management beyond configuration and repository workflows
- True assignee-bot ownership in Linear

## Open Questions

- Should v1 allow mention-driven sessions in addition to delegated sessions, or should delegation be
  the only supported intake path initially?
- What minimum GitHub App scopes are sufficient for the first production repositories?
- How much of the existing Symphony polling loop should remain active once Linear agent webhooks
  become the primary intake mechanism?

## Appendix: Source Constraints Incorporated Into This PRD

- Symphony remains the execution substrate.
- Repository-local workflow policy remains valid.
- v1 is single-tenant.
- Linear uses delegated agent ownership.
- GitHub uses an app identity.
- Codex is the only production provider in v1.
