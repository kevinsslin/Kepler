import { describe, expect, it } from "bun:test";
import { Orchestrator } from "../src/orchestrator/orchestrator.js";
import type { Issue } from "../src/domain/types.js";

function makeIssue(overrides: Partial<Issue> = {}): Issue {
  return {
    id: "issue-1",
    identifier: "SYM-1",
    title: "Test issue",
    description: null,
    priority: null,
    state: "Todo",
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

function makeOrchestrator(candidateIssues: Issue[]): Orchestrator {
  const config = {
    validate: async () => [],
    maxConcurrentAgentsForState: async () => 10,
    linearTerminalStates: async () => ["Done", "Cancelled"]
  };

  const tracker = {
    fetchCandidateIssues: async () => candidateIssues
  };

  return new Orchestrator(config as any, tracker as any, {} as any, {} as any);
}

describe("Orchestrator dispatch blocker rules", () => {
  it("does not dispatch Todo issues with non-terminal blockers", async () => {
    const blockedTodo = makeIssue({
      blocked_by: [{ id: "issue-2", identifier: "SYM-2", state: "In Progress" }]
    });

    const orchestrator = makeOrchestrator([blockedTodo]);
    const dispatched: string[] = [];

    (orchestrator as any).dispatchIssue = (issue: Issue): void => {
      dispatched.push(issue.id);
    };

    await (orchestrator as any).maybeDispatch();

    expect(dispatched).toHaveLength(0);
  });

  it("dispatches Todo issues only when all blockers are terminal", async () => {
    const readyTodo = makeIssue({
      blocked_by: [
        { id: "issue-2", identifier: "SYM-2", state: "Done" },
        { id: "issue-3", identifier: "SYM-3", state: "Cancelled" }
      ]
    });

    const orchestrator = makeOrchestrator([readyTodo]);
    const dispatched: string[] = [];

    (orchestrator as any).dispatchIssue = (issue: Issue): void => {
      dispatched.push(issue.id);
    };

    await (orchestrator as any).maybeDispatch();

    expect(dispatched).toEqual(["issue-1"]);
  });

  it("uses identifier as tie-breaker when priority and created_at are equal", async () => {
    const issueB = makeIssue({
      id: "issue-b",
      identifier: "SYM-20",
      priority: 1,
      created_at: "2026-01-01T00:00:00.000Z"
    });
    const issueA = makeIssue({
      id: "issue-a",
      identifier: "SYM-10",
      priority: 1,
      created_at: "2026-01-01T00:00:00.000Z"
    });

    const orchestrator = makeOrchestrator([issueB, issueA]);
    const dispatched: string[] = [];

    (orchestrator as any).dispatchIssue = (issue: Issue): void => {
      dispatched.push(issue.identifier);
    };

    await (orchestrator as any).maybeDispatch();

    expect(dispatched).toEqual(["SYM-10", "SYM-20"]);
  });
});
