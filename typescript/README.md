# Symphony TypeScript (Bun)

This directory contains the TypeScript/Bun implementation of Symphony.

For the canonical operational model, workflow expectations, and best-practice guidance, refer to
[../elixir/README.md](../elixir/README.md) and [../SPEC.md](../SPEC.md).

This README only covers TypeScript-specific setup and run commands.

## Prerequisites

- Bun 1.2+
- `codex` CLI available in your PATH
- Linear API key (`LINEAR_API_KEY`) or `tracker.api_key` in workflow file

## Install

```bash
cd typescript
bun install
```

## Run

```bash
bun run start -- --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

Optional flags:

- `--logs-root <path>`: set logs root (default unset)
- `--port <port>`: enable HTTP dashboard/API regardless of workflow `server.port`

If no workflow path is provided, Symphony uses `./WORKFLOW.md` in the current working directory.

## Workflow file

Use `WORKFLOW.example.md` as a starting point. It is aligned to the official long-form workflow
structure, with TypeScript-specific front matter values.

## TypeScript extensions

- Optional HTTP observability extension: `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`,
  `/api/v1/refresh`
- Optional app-server dynamic tool extension: `linear_graphql`

## Tests and checks

```bash
bun run check
bun test
```
