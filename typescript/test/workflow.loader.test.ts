import { describe, expect, it } from "bun:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { loadWorkflowFile } from "../src/workflow/loader.js";

describe("workflow loader", () => {
  it("parses yaml front matter and prompt", async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "symphony-wf-"));
    const workflowPath = path.join(dir, "WORKFLOW.md");

    await fs.writeFile(
      workflowPath,
      `---\ntracker:\n  kind: linear\npolling:\n  interval_ms: 5000\n---\n\nHello {{ issue.identifier }}\n`
    );

    const loaded = await loadWorkflowFile(workflowPath);
    expect((loaded.config.tracker as { kind: string }).kind).toBe("linear");
    expect((loaded.config.polling as { interval_ms: number }).interval_ms).toBe(5000);
    expect(loaded.prompt_template).toBe("Hello {{ issue.identifier }}");
  });

  it("accepts workflow with no front matter", async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "symphony-wf-"));
    const workflowPath = path.join(dir, "WORKFLOW.md");
    await fs.writeFile(workflowPath, "just prompt\n");

    const loaded = await loadWorkflowFile(workflowPath);
    expect(loaded.config).toEqual({});
    expect(loaded.prompt_template).toBe("just prompt");
  });

  it("loads long-form workflow templates without truncating prompt body", async () => {
    const workflowPath = path.resolve(process.cwd(), "WORKFLOW.example.md");
    const loaded = await loadWorkflowFile(workflowPath);

    expect((loaded.config.tracker as { kind: string }).kind).toBe("linear");
    expect((loaded.config.polling as { interval_ms: number }).interval_ms).toBe(5000);
    expect(loaded.prompt_template).toContain("## Step 0: Determine current ticket state and route");
    expect(loaded.prompt_template).toContain("## Workpad template");
  });
});
