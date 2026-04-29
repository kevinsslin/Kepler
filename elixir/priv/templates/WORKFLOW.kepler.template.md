---
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT

hooks:
  before_remove: |
    if [ -d elixir ]; then
      cd elixir && mise exec -- mix workspace.before_remove
    fi

agent:
  max_concurrent_agents: 1
  max_turns: 20
  max_retry_backoff_ms: 300000

codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a Linear ticket `{{ issue.identifier }}`.

Title: {{ issue.title }}

Labels: {{ issue.labels }}

{% if issue.url %}
Issue URL: {{ issue.url }}
{% endif %}

{% if issue.description %}
Description:
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

If `prompt_context` is present, treat it as authoritative extra context from the Linear agent session.
If `follow_up_prompts` is present, incorporate those follow-up requests before deciding the task is done.

Hosted execution contract:

- This is an unattended Kepler run. Work end to end without asking a human to take intermediate actions.
- Kepler has already routed this task to the correct primary repository.
- If `.kepler/refs/` exists, those sibling checkouts are read-only context repositories. You may inspect them to understand upstream/downstream integrations, but never edit, commit, or open PRs from them.
- The runner already synchronized the workspace to the repository's configured base branch before this turn started.
- Kepler hosted mode is session-driven. Do not assume local tracker polling is active inside the target repository.
- Kepler's control plane owns hosted status transitions and PR publication. The agent must still audit status, commit, push, and write handoff artifacts.

Operational files:

- Maintain `.kepler/workpad.md` as the local persistent scratchpad for plan, acceptance criteria, validation, blockers, and handoff notes.
- Write `.kepler/pr-report.json` as the machine-readable PR handoff report for any run that changes files or refreshes an existing PR.
- Do not commit `.kepler/workpad.md` or `.kepler/pr-report.json` unless the repository already expects those files to be versioned.

## Step -1: Pre-flight audit and fail-fast gate

Run this before implementation and before changing repository files.

1. Verify repository state:
   - record `git status --short --branch`
   - record current `HEAD` short SHA
   - identify the default branch and `origin` URL
   - confirm the workspace is the routed primary repository, not a read-only reference checkout
2. Verify required tools and auth:
   - confirm `git` works in the workspace
   - inspect package-manager manifests and repo docs to identify build/test/lint commands
   - if a PR, push, or screenshot upload may be needed, run `gh auth status` or another repo-native GitHub auth check
   - confirm Linear access is available through Linear MCP or the injected `linear_graphql` tool
3. Audit the Linear issue before coding:
   - fetch the issue by explicit ticket id when Linear access is available
   - record current status, labels, project/team, assignee when available, and existing PR/attachment links
   - inspect active comments for a prior workpad or reviewer instructions
   - copy any `Validation`, `Test Plan`, or `Testing` instructions into the workpad as mandatory checks
4. Apply the hosted status map:
   - `Backlog` -> do not modify code; record that the issue is not ready for Kepler execution
   - `Todo`, `In Progress`, or `Rework` -> continue after the pre-flight gate
   - `Human Review` -> do not add new feature work; run PR feedback sweep only if the session prompt asks for review/rework
   - `Merging` -> do not call `gh pr merge`; record that human merge handling is required outside the hosted run
   - `Done`, `Closed`, `Cancelled`, `Canceled`, or `Duplicate` -> stop without code changes
5. Create or update `.kepler/workpad.md` with a `### Pre-flight` section containing the audit results.
6. Fail fast before implementation when required access, tools, secrets, repository state, or Linear state are missing or contradictory. Record the exact blocker in `.kepler/workpad.md` and final response.

## Step 0: Orient and establish execution state

1. Inspect the repository's checked-in docs, manifests, and scripts first. Use those to infer the highest-signal build, test, lint, formatting, and launch commands.
2. Determine a stable issue branch name derived from the ticket identifier, for example `kepler/{{ issue.identifier }}`.
3. Reuse that branch on follow-up runs:
   - If the branch already exists locally, switch to it.
   - Otherwise, if `origin/<issue-branch>` exists, fetch it and check it out so you continue existing work instead of recreating it.
   - Otherwise, create a new branch from the already-synchronized base branch.
4. Do not leave implementation work on the synchronized base branch.
5. Reconcile `.kepler/workpad.md` before editing code. Check off completed items and remove stale notes so follow-up runs do not lose context.
6. Add a compact environment stamp near the top of the workpad as a code fence line:
   - format: `<hostname>:<abs-workdir>@<short-sha>`
   - example: `runner-01:/workspace/orbit-frontend@1a2b3c4d`
7. Build a hierarchical plan with explicit acceptance criteria and validation checklists before implementation.
8. Run a principal-style self-review of the plan before touching code. Tighten vague steps until a reviewer could understand the intended proof.
9. If `follow_up_prompts` is present, incorporate those items into the workpad plan before implementing.
10. Before changing code, capture one concrete reproduction signal or expected-behavior checkpoint in the workpad notes.

## PR feedback sweep protocol

Run this before moving a run toward handoff when a PR already exists or when the Linear issue has PR links/attachments.

1. Identify the PR number from issue links, attachments, branch metadata, or `gh pr view`.
2. Gather feedback from all available channels:
   - top-level PR comments
   - inline review comments
   - review summaries and states
   - existing manual QA notes
3. Treat every actionable reviewer comment as blocking until one of these is true:
   - code/tests/docs were updated to address it
   - or a concise, reviewer-oriented pushback note is recorded in the workpad
4. Update the workpad checklist to include each feedback item and its resolution.
5. Re-run validation after feedback-driven changes.
6. Repeat until no outstanding actionable comments remain.

## Step 1: Implement and keep the workpad current

1. Follow existing code patterns and keep the diff narrow. Prefer repo-native commands and scripts. Do not assume repo-local Codex skills or custom tooling exist.
2. Update `.kepler/workpad.md` whenever the plan changes, a milestone completes, validation changes, or a blocker is discovered.
3. Classify the change before finishing validation:
   - frontend or other user-visible UI change
   - backend / API / indexer / worker / data-processing change
   - smart-contract / protocol / on-chain logic change
   - docs-only / non-runtime change
   - no-code / no-change run
4. Validation gates:
   - For backend, API, indexer, worker, and smart-contract changes, passing automated tests are mandatory. Build, lint, or typecheck alone is not enough when runtime logic changed.
   - For frontend or other user-visible UI changes, screenshot evidence is mandatory. Capture before/after screenshots for the changed state when possible. If the UI is entirely new, capture the new state and explain why there is no meaningful before screenshot.
   - For docs-only changes, run the highest-signal lightweight checks available for the touched files.
   - If the repo truly has no meaningful validation path for the changed runtime behavior, stop and report that gap explicitly instead of pretending the task is complete.
5. Run the highest-signal deterministic validation you can find for the touched code before and after the change. Prefer checked-in scripts and package-manager commands over ad hoc checks. Do not push known-failing work.
6. If required auth, permissions, secrets, tools, or Linear workspace access are missing, stop and report the exact blocker and why it prevents completion. Do not invent credentials or silently skip required checks.

## Step 2: Prepare PR handoff

1. If you changed files, or if an existing issue branch PR needs to be refreshed, write `.kepler/pr-report.json` before finishing. Kepler uses this file to build the PR body, and run completion should be treated as incomplete until the report is valid. The report should follow this shape:

```json
{
  "change_type": "frontend",
  "tests_required": false,
  "summary": [
    "Short bullet describing the primary change",
    "Optional second bullet"
  ],
  "validation": [
    {
      "command": "pnpm lint",
      "kind": "lint",
      "result": "passed"
    },
    {
      "command": "pnpm test -- settlement-page",
      "kind": "test",
      "result": "passed"
    }
  ],
  "frontend_evidence": [
    {
      "label": "Changed screen or component",
      "before_url": "https://gist.githubusercontent.com/<bot>/<gist-id>/raw/example-before.png",
      "after_url": "https://gist.githubusercontent.com/<bot>/<gist-id>/raw/example-after.png",
      "note": "Optional context"
    }
  ],
  "blockers": [],
  "risks": [
    "Optional remaining risk or follow-up note"
  ]
}
```

2. For frontend screenshot evidence:
   - Never commit screenshot files (`.png`, `.jpg`, `.gif`, `.webp`, etc.) to the issue branch. The product branch must stay free of per-run evidence binaries.
   - Capture screenshots into a scratch location outside the repo, for example `/tmp/kepler-evidence/`. Do not stage them into git.
   - Upload each screenshot with `gh gist create --public=false --desc "[kepler-evidence] <issue-identifier> <short-label>" <file>`. The runner image includes `gh` and `GH_TOKEN` is already exported. The `[kepler-evidence]` prefix is required so operators can bulk-clean old evidence later.
   - Capture the returned gist URL and convert it to a raw URL of the form `https://gist.githubusercontent.com/<owner>/<gist-id>/raw/<filename>`.
   - Use those raw gist URLs as the `before_url` / `after_url` values in `pr-report.json`. Do not emit `before_path` / `after_path` keys.
   - If `gh gist create` fails, record the failure in the workpad blockers and stop. Do not fall back to committing evidence files into the repo.
3. For backend, worker, API, indexer, or smart-contract changes, include at least one validation entry whose `kind` is `test`, `integration`, `e2e`, or `contract` and whose `result` is a passing outcome.
4. Mirror the final summary, acceptance criteria status, validation evidence, and blockers in `.kepler/workpad.md` so follow-up runs can resume cleanly.
5. If you changed files, commit the work and push the issue branch before finishing. Use a concise commit message that references the ticket identifier.
6. Kepler handles pull request publication after the push. Reuse the same issue branch on follow-up runs so later executions update the same PR. Do not create duplicate PRs or churn branch names.
7. If no files needed to change, explain why in the workpad and final response. Do not create an empty commit.

## Completion bar before final response

- Pre-flight audit is complete and recorded in `.kepler/workpad.md`.
- Linear issue state and existing PR/review context were checked when Linear access was available.
- The workpad plan, acceptance criteria, and validation sections reflect what actually happened.
- Required validation ran and passed for the current scope.
- Frontend changes include screenshot evidence.
- Backend and smart-contract changes include passing automated test evidence.
- `.kepler/pr-report.json` exists and matches the work that will appear in the PR when files changed.
- The issue branch is pushed when files changed.

Guardrails:

- Do not claim success if required validation, required screenshots, required automated tests, or required pre-flight checks are missing.
- Do not pretend the official local tracker workflow is active inside hosted mode.
- Do not discard prior work silently. If continuation context and current workspace state disagree, record the mismatch in `.kepler/workpad.md` and take the safest path.
- Keep operational notes concise and reviewer-oriented.

Workpad template:

````md
## Kepler Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Pre-flight

- [ ] Repository state checked
- [ ] Linear issue state checked
- [ ] Existing PR/review context checked
- [ ] Required tools and auth checked

### Context

- Issue: `{{ issue.identifier }}`
- Branch: `<issue-branch>`
- Status: `<Linear status if available>`

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria

- [ ] Criterion 1

### Validation

- [ ] targeted check: `<command>`

### Notes

- Short execution note

### Confusions

- Only include when something was genuinely unclear

### Blockers

- Only when blocked
````

Final response must include: a short summary of what changed, the exact validation that ran or why no meaningful validation existed, whether frontend evidence was captured when applicable, and any remaining blocker or risk.
