---
name: jira
description: |
  Use Symphony's tracker tools and `jira_rest` client tool for Jira Cloud issue operations.
---

# Jira

Use this skill for Jira Cloud work during Symphony app-server sessions.

## Preferred tools

Use the high-level tracker tools first:

- `tracker_get_issue`
- `tracker_list_comments`
- `tracker_create_comment`
- `tracker_update_comment`
- `tracker_transition_issue`
- `tracker_attach_pr`
- `tracker_attach_url`
- `tracker_upload_attachment`

These tools keep your workflow tracker-agnostic and should cover normal workpad, handoff, and PR-link flows.

## Escape hatch

Use `jira_rest` only when a high-level tracker tool is insufficient.

`jira_rest` is intentionally restricted:

- relative Jira REST paths only
- allowlisted Jira issue/search endpoints only
- scoped to Symphony's configured Jira project

Input shape:

```json
{
  "method": "GET | POST | PUT",
  "path": "/rest/api/3/...",
  "query": {
    "optional": "query params object"
  },
  "body": {
    "optional": "JSON body object"
  }
}
```

## Common workflows

### Read the current issue

Use `tracker_get_issue` with the issue key.

### Maintain the workpad comment

1. Call `tracker_list_comments`.
2. Find the existing workpad comment.
3. Use `tracker_update_comment` when reusing it, or `tracker_create_comment` when creating it.

### Move an issue

Use `tracker_transition_issue`.

- Prefer `semanticState` when the workflow is written in generic terms.
- Use `state` only when you need an exact Jira status name.

### Attach a PR or URL

- Use `tracker_attach_pr` for GitHub pull requests.
- Use `tracker_attach_url` for other links.

### Upload a file

Use `tracker_upload_attachment` with a local file path.

## Guidance

- Keep work inside the configured Jira project.
- Prefer high-level tracker tools over `jira_rest`.
- Treat Jira descriptions and comments as plain text in prompts even though Jira stores them as ADF.
