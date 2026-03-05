import { describe, expect, it } from "bun:test";
import { Orchestrator } from "../src/orchestrator/orchestrator.js";
import type { Issue } from "../src/domain/types.js";

function makeIssue(overrides: Partial<Issue> = {}): Issue {
  return {
    id: "issue-1",
    identifier: "SYM-1",
    title: "Retry issue",
    description: null,
    priority: null,
    state: "In Progress",
    branch_name: null,
    url: null,
    labels: [],
    blocked_by: [],
    assignee_id: null,
    created_at: null,
    updated_at: null,
    ...overrides
  };
}

describe("Orchestrator retry scheduling", () => {
  it("falls back to default max backoff when config read fails", async () => {
    const issue = makeIssue();
    const scheduled: { issueId: string; attempt: number; error: string | null; delayMs: number }[] = [];

    const orchestrator = new Orchestrator(
      {
        maxRetryBackoffMs: async () => {
          throw new Error("config_unavailable");
        }
      } as any,
      {} as any,
      {} as any,
      {
        run: async () => {
          throw new Error("run_failed");
        }
      } as any
    );

    (orchestrator as any).scheduleIssueRetry = (
      issueId: string,
      attempt: number,
      metadata: { identifier: string; error: string | null },
      delayMs: number
    ): void => {
      scheduled.push({ issueId, attempt, error: metadata.error, delayMs });
    };

    (orchestrator as any).dispatchIssue(issue, null);
    const runningEntry = (orchestrator as any).running.get(issue.id);
    await runningEntry?.finished;

    expect(scheduled).toHaveLength(1);
    expect(scheduled[0]?.issueId).toBe(issue.id);
    expect(scheduled[0]?.attempt).toBe(1);
    expect(scheduled[0]?.error).toBe("run_failed");
    expect(scheduled[0]?.delayMs).toBe(10_000);
  });
});
