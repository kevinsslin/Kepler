import { describe, expect, it } from "bun:test";
import { sanitizeWorkspaceKey } from "../src/workspace/manager.js";

describe("workspace key sanitize", () => {
  it("replaces unsafe characters", () => {
    expect(sanitizeWorkspaceKey("MT-42/unsafe name")).toBe("MT-42_unsafe_name");
  });

  it("uses issue fallback", () => {
    expect(sanitizeWorkspaceKey("")).toBe("issue");
    expect(sanitizeWorkspaceKey(null)).toBe("issue");
  });
});
