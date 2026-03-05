import nunjucks from "nunjucks";
import type { Issue } from "../domain/types.js";
import { ConfigStore } from "../config/config.js";

function toTemplateValue(value: unknown): unknown {
  if (value instanceof Date) {
    return value.toISOString();
  }

  if (Array.isArray(value)) {
    return value.map((entry) => toTemplateValue(entry));
  }

  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value)) {
      out[key] = toTemplateValue(entry);
    }
    return out;
  }

  return value;
}

export class PromptBuilder {
  private readonly env: nunjucks.Environment;

  constructor(private readonly config: ConfigStore) {
    this.env = new nunjucks.Environment(undefined, {
      throwOnUndefined: true,
      autoescape: false,
      trimBlocks: false,
      lstripBlocks: false
    });
  }

  async buildPrompt(issue: Issue, attempt: number | null): Promise<string> {
    const template = await this.config.workflowPromptTemplate();
    const rendered = this.env.renderString(template, {
      attempt,
      issue: toTemplateValue(issue)
    });

    return rendered;
  }

  buildContinuationPrompt(turnNumber: number, maxTurns: number): string {
    return [
      "Continuation guidance:",
      "",
      "- The previous Codex turn completed normally, but the issue remains in an active state.",
      `- This is continuation turn #${turnNumber} of ${maxTurns} for this worker run.`,
      "- Resume from the current workspace state and avoid repeating completed work.",
      "- Focus only on remaining ticket scope; do not ask for operator input."
    ].join("\n");
  }
}
