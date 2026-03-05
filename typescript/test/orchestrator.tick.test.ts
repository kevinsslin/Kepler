import { describe, expect, it } from "bun:test";
import { Orchestrator } from "../src/orchestrator/orchestrator.js";

describe("Orchestrator tick lifecycle", () => {
  it("reschedules polling even when runtime refresh fails", async () => {
    const orchestrator = new Orchestrator({} as any, {} as any, {} as any, {} as any);
    const scheduled: number[] = [];

    (orchestrator as any).started = true;
    (orchestrator as any).pollIntervalMs = 2_500;
    (orchestrator as any).refreshRuntimeConfig = async () => {
      throw new Error("bad_workflow");
    };
    (orchestrator as any).scheduleTick = (delayMs: number): void => {
      scheduled.push(delayMs);
    };

    await (orchestrator as any).tick();

    expect(scheduled).toEqual([2_500]);
    expect((orchestrator as any).pollCheckInProgress).toBe(false);
  });
});
