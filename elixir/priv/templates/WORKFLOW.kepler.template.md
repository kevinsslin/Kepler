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
  command: "$CODEX_BIN --config model_reasoning_effort=high --model gpt-5.4 app-server"
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
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
- Kepler has already routed this task to the correct repository. Stay inside this workspace and do not attempt cross-repo work.
- The runner already synchronized the workspace to the repository's configured base branch before this turn started.
- Kepler hosted mode is session-driven. Do not assume tracker polling, issue state transitions, or Linear comment editing are available inside the run.

Operational files:

- Maintain `.kepler/workpad.md` as the local persistent scratchpad for plan, acceptance criteria, validation, and handoff notes.
- Write `.kepler/pr-report.json` as the machine-readable PR handoff report for any run that changes files or updates an existing PR.
- Do not commit `.kepler/workpad.md` or `.kepler/pr-report.json` unless the repository already expects those files to be versioned.

Default posture:

- Spend extra effort up front on understanding the issue, reproducing the current behavior, and deciding the smallest correct change.
- Treat any issue-authored `Validation`, `Test Plan`, or `Testing` instructions as required acceptance input.
- Prefer checked-in repository docs, scripts, manifests, and package-manager commands over ad hoc workflows.
- Operate autonomously end to end unless you are blocked by missing required auth, permissions, secrets, or tooling.
- Do not claim validation you did not run.
- Keep one persistent local workpad updated as execution reality changes.

Required workflow:

## Step 0: Orient and establish execution state

1. Inspect the repository's checked-in docs, manifests, and scripts first. Use those to infer the highest-signal build, test, lint, formatting, and launch commands.
2. Determine a stable issue branch name derived from the ticket identifier, for example `kepler/{{ issue.identifier }}`.
3. Reuse that branch on follow-up runs:
   - If the branch already exists locally, switch to it.
   - Otherwise, if `origin/<issue-branch>` exists, fetch it and check it out so you continue existing work instead of recreating it.
   - Otherwise, create a new branch from the already-synchronized base branch.
4. Do not leave implementation work on the synchronized base branch.
5. Create or update `.kepler/workpad.md` before editing code. Reconcile any existing checkboxes and notes before adding new work so follow-up runs do not lose context.
6. Add a compact environment stamp near the top of the workpad as a code fence line:
   - format: `<hostname>:<abs-workdir>@<short-sha>`
   - example: `runner-01:/workspace/orbit-frontend@1a2b3c4d`
7. Build a hierarchical plan with explicit acceptance criteria and validation checklists before implementation. If the issue description includes `Validation`, `Test Plan`, or `Testing`, copy those requirements into the workpad and treat them as mandatory.
8. Run a principal-style self-review of the plan before you touch code. Tighten vague steps until a reviewer could understand the intended proof.
9. If `follow_up_prompts` is present, incorporate those items into the workpad plan before implementing.
10. Before changing code, capture one concrete reproduction signal or expected-behavior checkpoint in the workpad notes.

## Step 1: Implement and keep the workpad current

1. Follow existing code patterns and keep the diff narrow. Prefer repo-native commands and scripts. Do not assume repo-local Codex skills or custom tooling exist.
2. Update `.kepler/workpad.md` whenever the plan changes, a milestone completes, validation changes, or a blocker is discovered.
3. Classify the change before you finish validation:
   - frontend or other user-visible UI change
   - backend / API / indexer / worker / data-processing change
   - smart-contract / protocol / on-chain logic change
   - docs-only / non-runtime change
4. Validation gates:
   - For backend, API, indexer, worker, and smart-contract changes, passing automated tests are mandatory. Build, lint, or typecheck alone is not enough when runtime logic changed.
   - For frontend or other user-visible UI changes, screenshot evidence is mandatory. Capture before/after screenshots for the changed state when possible. If the UI is entirely new, capture the new state and explain why there is no meaningful before screenshot.
   - For docs-only changes, run the highest-signal lightweight checks available for the touched files.
   - If the repo truly has no meaningful validation path for the changed runtime behavior, stop and report that gap explicitly instead of pretending the task is complete.
5. Run the highest-signal deterministic validation you can find for the touched code before and after the change. Prefer checked-in scripts and package-manager commands over ad hoc checks. Do not push known-failing work.
6. If `gh` is available and the issue branch already has an open PR, run a lightweight PR feedback sweep before declaring the run complete:
   - inspect top-level PR comments
   - inspect inline review comments
   - inspect review summaries and states
   - treat actionable comments as blocking unless you updated code/tests/docs or have a clear, reviewer-oriented pushback note in the workpad
7. If required auth, permissions, secrets, or tools are missing, stop and report the exact blocker and why it prevents completion. Do not invent credentials or silently skip required checks.

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
      "before_path": ".kepler/evidence/example-before.png",
      "after_path": ".kepler/evidence/example-after.png",
      "before_url": "https://example.com/example-before.png",
      "after_url": "https://example.com/example-after.png",
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
   - Prefer `before_url` / `after_url` when you already have stable hosted artifact URLs.
   - Otherwise use `before_path` / `after_path` with stable relative paths such as `.kepler/evidence/...` and make sure those assets exist, are committed on the issue branch, and are pushed before the run finishes so the PR body can render them from GitHub.
3. For backend, worker, API, indexer, or smart-contract changes, include at least one validation entry whose `kind` is `test`, `integration`, `e2e`, or `contract` and whose `result` is a passing outcome.
4. Mirror the final summary, acceptance criteria status, validation evidence, and blockers in `.kepler/workpad.md` so follow-up runs can resume cleanly.
5. If you changed files, commit the work and push the issue branch before finishing. Use a concise commit message that references the ticket identifier.
6. Kepler handles pull request publication after the push. Reuse the same issue branch on follow-up runs so later executions update the same PR. Do not create duplicate PRs or churn branch names.
7. If no files needed to change, explain why in the workpad and final response. Do not create an empty commit.

## Completion bar before final response

- The workpad plan, acceptance criteria, and validation sections reflect what actually happened.
- Required validation ran and passed for the current scope.
- Frontend changes include screenshot evidence.
- Backend and smart-contract changes include passing automated test evidence.
- `.kepler/pr-report.json` exists and matches the work that will appear in the PR.
- The issue branch is pushed when files changed.

Guardrails:

- Do not claim success if required validation, required screenshots, or required automated tests are missing.
- Do not pretend the official local tracker workflow is active inside hosted mode.
- Do not discard prior work silently; if continuation context and current workspace state disagree, record the mismatch in `.kepler/workpad.md` and take the safest path.
- Keep operational notes concise and reviewer-oriented.

Workpad template:

````md
## Kepler Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Context

- Issue: `{{ issue.identifier }}`
- Branch: `<issue-branch>`

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

Final response must include: a short summary of what changed, the exact validation that ran (or why no meaningful validation existed), whether frontend evidence was captured when applicable, and any remaining blocker or risk.
