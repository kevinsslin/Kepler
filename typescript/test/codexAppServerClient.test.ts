import { describe, expect, it } from "bun:test";
import os from "node:os";
import path from "node:path";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { CodexAppServerClient, type CodexSession } from "../src/agent/codexAppServerClient.js";
import type { Issue } from "../src/domain/types.js";

const ISSUE_FIXTURE: Issue = {
  id: "issue-1",
  identifier: "SYM-1",
  title: "Race check",
  description: null,
  priority: null,
  state: "In Progress",
  branch_name: null,
  url: null,
  labels: [],
  blocked_by: [],
  assignee_id: null,
  created_at: null,
  updated_at: null
};

const FAKE_SERVER = `
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

rl.on("line", (line) => {
  const message = JSON.parse(line);

  if (message.method === "initialize") {
    process.stdout.write(JSON.stringify({ id: message.id, result: {} }) + "\\n");
    return;
  }

  if (message.method === "thread/start") {
    process.stdout.write(JSON.stringify({ id: message.id, result: { thread: { id: "thread-1" } } }) + "\\n");
    return;
  }

  if (message.method === "turn/start") {
    process.stdout.write(
      JSON.stringify({ id: message.id, result: { turn: { id: "turn-1" } } }) + "\\n" +
        JSON.stringify({ method: "turn/completed", params: { turn: { id: "turn-1" } } }) + "\\n"
    );
  }
});

setInterval(() => {}, 1000);
`;

describe("CodexAppServerClient", () => {
  it("handles immediate turn completion after turn/start", async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "symphony-codex-test-"));
    const serverPath = path.join(tempRoot, "fake-codex-server.mjs");

    let session: CodexSession | null = null;

    try {
      await writeFile(serverPath, FAKE_SERVER, "utf8");

      const client = new CodexAppServerClient(
        {
          codexCommand: async () => `node ${JSON.stringify(serverPath)}`,
          codexRuntimeSettings: async () => ({
            approval_policy: "never",
            thread_sandbox: "workspace-write",
            turn_sandbox_policy: { type: "workspaceWrite" }
          }),
          codexReadTimeoutMs: async () => 2_000,
          codexTurnTimeoutMs: async () => 2_000
        } as any,
        {
          specs: () => [],
          execute: async () => ({ success: true, contentItems: [] })
        } as any
      );

      session = await client.startSession(tempRoot);

      const updates: string[] = [];
      const result = await session.runTurn("hello", ISSUE_FIXTURE, (update) => {
        updates.push(update.event);
      });

      expect(result.turnId).toBe("turn-1");
      expect(result.sessionId).toBe("thread-1-turn-1");
      expect(updates).toContain("turn_completed");
    } finally {
      if (session) {
        await session.stop();
      }

      await rm(tempRoot, { recursive: true, force: true });
    }
  });
});
