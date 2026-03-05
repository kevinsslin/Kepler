import { describe, expect, it } from "bun:test";
import { nextDelayWithBackoff } from "../src/utils/time.js";

describe("nextDelayWithBackoff", () => {
  it("doubles delay for small attempts", () => {
    expect(nextDelayWithBackoff(100, 1, 10_000)).toBe(100);
    expect(nextDelayWithBackoff(100, 2, 10_000)).toBe(200);
    expect(nextDelayWithBackoff(100, 3, 10_000)).toBe(400);
  });

  it("caps large attempts without 32-bit overflow", () => {
    expect(nextDelayWithBackoff(100, 40, 300_000)).toBe(300_000);
    expect(nextDelayWithBackoff(100, 80, 300_000)).toBe(300_000);
  });
});
