import { describe, expect, it } from "bun:test";
import { LinearClient } from "../src/tracker/linearClient.js";

function makeIssueNode(id: string): Record<string, unknown> {
  const index = id.split("-").at(-1) ?? "0";
  return {
    id,
    identifier: `SYM-${index}`,
    title: `Issue ${index}`,
    description: null,
    priority: 0,
    state: { name: "In Progress" },
    branchName: null,
    url: null,
    assignee: { id: null },
    labels: { nodes: [] },
    inverseRelations: { nodes: [] },
    createdAt: null,
    updatedAt: null
  };
}

describe("LinearClient.fetchIssueStatesByIds", () => {
  it("paginates until all requested IDs are fetched", async () => {
    const ids = Array.from({ length: 55 }, (_, index) => `id-${index + 1}`);

    const client = new LinearClient({
      linearAssignee: async () => null
    } as any);

    const seenAfter: Array<string | null | undefined> = [];
    let callCount = 0;

    (client as any).graphql = async (_query: string, variables: Record<string, unknown>) => {
      callCount += 1;
      const first = Number(variables.first ?? 50);
      const after = (variables.after as string | null | undefined) ?? null;
      seenAfter.push(after);

      const start = after === "cursor-1" ? 50 : 0;
      const pageIds = ids.slice(start, start + first);

      return {
        issues: {
          nodes: pageIds.map((id) => makeIssueNode(id)),
          pageInfo: {
            hasNextPage: start + first < ids.length,
            endCursor: start + first < ids.length ? "cursor-1" : null
          }
        }
      };
    };

    const issues = await client.fetchIssueStatesByIds(ids);

    expect(callCount).toBe(2);
    expect(seenAfter).toEqual([null, "cursor-1"]);
    expect(issues).toHaveLength(ids.length);
    expect(issues[0]?.id).toBe("id-1");
    expect(issues.at(-1)?.id).toBe("id-55");
  });

  it("does not apply assignee filter for issue-id refresh", async () => {
    const client = new LinearClient({
      linearAssignee: async () => "user-1"
    } as any);

    (client as any).graphql = async () => ({
      issues: {
        nodes: [
          {
            id: "id-1",
            identifier: "SYM-1",
            title: "Issue 1",
            description: null,
            priority: 0,
            state: { name: "In Progress" },
            branchName: null,
            url: null,
            assignee: { id: "user-2" },
            labels: { nodes: [] },
            inverseRelations: { nodes: [] },
            createdAt: null,
            updatedAt: null
          }
        ],
        pageInfo: {
          hasNextPage: false,
          endCursor: null
        }
      }
    });

    const issues = await client.fetchIssueStatesByIds(["id-1"]);
    expect(issues).toHaveLength(1);
    expect(issues[0]?.assignee_id).toBe("user-2");
  });
});

describe("LinearClient.graphqlRaw", () => {
  it("aborts stalled requests when timeout elapses", async () => {
    const originalFetch = globalThis.fetch;

    globalThis.fetch = ((_input: RequestInfo | URL, init?: RequestInit) => {
      return new Promise<Response>((_resolve, reject) => {
        const signal = init?.signal;
        if (!signal) {
          reject(new Error("missing_signal"));
          return;
        }

        signal.addEventListener(
          "abort",
          () => {
            reject(new DOMException("Aborted", "AbortError"));
          },
          { once: true }
        );
      });
    }) as typeof fetch;

    try {
      const client = new LinearClient({
        linearApiToken: async () => "token",
        linearEndpoint: async () => "https://api.linear.app/graphql",
        linearRequestTimeoutMs: async () => 5
      } as any);

      await expect(client.graphqlRaw("query Q { __typename }")).rejects.toThrow("linear_request_timeout");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

describe("LinearClient.fetchCandidateIssues", () => {
  it("fails closed when tracker.assignee=me viewer lookup fails", async () => {
    const client = new LinearClient({
      linearProjectSlug: async () => "proj",
      linearActiveStates: async () => ["Todo", "In Progress"],
      linearAssignee: async () => "me"
    } as any);

    (client as any).graphql = async (query: string) => {
      if (query.includes("viewer")) {
        throw new Error("temporary_linear_error");
      }

      return {
        issues: {
          nodes: [],
          pageInfo: {
            hasNextPage: false,
            endCursor: null
          }
        }
      };
    };

    await expect(client.fetchCandidateIssues()).rejects.toThrow("linear_viewer_lookup_failed");
  });
});
