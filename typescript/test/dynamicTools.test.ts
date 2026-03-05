import { describe, expect, it } from "bun:test";
import { DynamicTools } from "../src/agent/dynamicTools.js";

describe("dynamic tools", () => {
  it("rejects multiple operations", async () => {
    const tools = new DynamicTools(
      {
        trackerKind: async () => "linear"
      } as any,
      {
        graphqlRaw: async () => ({ data: {} })
      } as any
    );

    const result = await tools.execute("linear_graphql", {
      query: "query A { __typename } query B { __typename }"
    });

    expect(result.success).toBe(false);
    expect(result.contentItems[0]?.text).toContain("exactly one operation");
  });

  it("passes through valid graphql", async () => {
    const tools = new DynamicTools(
      {
        trackerKind: async () => "linear"
      } as any,
      {
        graphqlRaw: async () => ({ data: { issue: { id: "1" } } })
      } as any
    );

    const result = await tools.execute("linear_graphql", {
      query: "query Q { __typename }"
    });

    expect(result.success).toBe(true);
    expect(result.contentItems[0]?.text).toContain("data");
  });

  it("preserves graphql error payload", async () => {
    const tools = new DynamicTools(
      {
        trackerKind: async () => "linear"
      } as any,
      {
        graphqlRaw: async () => ({ errors: [{ message: "boom" }] })
      } as any
    );

    const result = await tools.execute("linear_graphql", {
      query: "query Q { __typename }"
    });

    expect(result.success).toBe(false);
    expect(result.contentItems[0]?.text).toContain("boom");
  });
});
