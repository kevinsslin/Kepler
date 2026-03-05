import fs from "node:fs/promises";
import path from "node:path";
import { load as loadYaml } from "js-yaml";
import type { WorkflowDefinition } from "../domain/types.js";

export class WorkflowError extends Error {
  constructor(message: string, readonly code: string, readonly details?: unknown) {
    super(message);
    this.name = "WorkflowError";
  }
}

function splitFrontMatter(content: string): { yaml: string; prompt: string } {
  const lines = content.split(/\r?\n/);
  if (lines[0] !== "---") {
    return { yaml: "", prompt: content.trim() };
  }

  const endIdx = lines.findIndex((line, idx) => idx > 0 && line === "---");
  if (endIdx === -1) {
    return {
      yaml: lines.slice(1).join("\n"),
      prompt: ""
    };
  }

  return {
    yaml: lines.slice(1, endIdx).join("\n"),
    prompt: lines.slice(endIdx + 1).join("\n").trim()
  };
}

function parseFrontMatter(yaml: string): Record<string, unknown> {
  if (yaml.trim() === "") {
    return {};
  }

  const decoded = loadYaml(yaml);
  if (decoded == null) {
    return {};
  }

  if (typeof decoded !== "object" || Array.isArray(decoded)) {
    throw new WorkflowError(
      "Workflow front matter must decode to an object.",
      "workflow_front_matter_not_a_map"
    );
  }

  return decoded as Record<string, unknown>;
}

export async function loadWorkflowFile(filePath: string): Promise<WorkflowDefinition> {
  const expanded = path.resolve(filePath);

  let content: string;
  try {
    content = await fs.readFile(expanded, "utf8");
  } catch (error) {
    throw new WorkflowError(
      `Workflow file not found: ${expanded}`,
      "missing_workflow_file",
      error
    );
  }

  const { yaml, prompt } = splitFrontMatter(content);

  try {
    const config = parseFrontMatter(yaml);

    return {
      config,
      prompt,
      prompt_template: prompt
    };
  } catch (error) {
    if (error instanceof WorkflowError) {
      throw error;
    }

    throw new WorkflowError("Failed to parse workflow YAML front matter.", "workflow_parse_error", error);
  }
}

export async function workflowMtimeMs(filePath: string): Promise<number> {
  const expanded = path.resolve(filePath);
  const stat = await fs.stat(expanded);
  return stat.mtimeMs;
}
