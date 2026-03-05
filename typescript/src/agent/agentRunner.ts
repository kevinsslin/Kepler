import type { Issue } from "../domain/types.js";
import { ConfigStore } from "../config/config.js";
import { logger } from "../logging/logger.js";
import { PromptBuilder } from "../prompt/promptBuilder.js";
import { WorkspaceManager } from "../workspace/manager.js";
import { LinearClient } from "../tracker/linearClient.js";
import { CodexAppServerClient, type CodexUpdate } from "./codexAppServerClient.js";

export interface AgentRunResult {
  workspacePath: string;
  issue: Issue;
}

export class AgentRunner {
  constructor(
    private readonly config: ConfigStore,
    private readonly workspace: WorkspaceManager,
    private readonly promptBuilder: PromptBuilder,
    private readonly tracker: LinearClient,
    private readonly codex: CodexAppServerClient
  ) {}

  async run(
    issue: Issue,
    attempt: number | null,
    onUpdate: (update: CodexUpdate) => void,
    abortSignal: AbortSignal
  ): Promise<AgentRunResult> {
    const workspace = await this.workspace.createForIssue(issue);
    await this.workspace.runBeforeRunHook(workspace.path, issue);

    const session = await this.codex.startSession(workspace.path);
    const onAbort = () => {
      session.abortTurn("run_aborted");
    };
    abortSignal.addEventListener("abort", onAbort);

    try {
      const maxTurns = await this.config.agentMaxTurns();
      let turn = 1;
      let currentIssue = issue;

      while (turn <= maxTurns) {
        if (abortSignal.aborted) {
          throw new Error("run_aborted");
        }

        const prompt =
          turn === 1
            ? await this.promptBuilder.buildPrompt(currentIssue, attempt)
            : this.promptBuilder.buildContinuationPrompt(turn, maxTurns);

        await session.runTurn(prompt, currentIssue, onUpdate);

        const refreshed = await this.tracker.fetchIssueStatesByIds([currentIssue.id]);
        const updated = refreshed[0] ?? currentIssue;
        currentIssue = updated;

        const activeStates = await this.config.linearActiveStates();
        const normalizedState = (updated.state ?? "").trim().toLowerCase();
        const stillActive = activeStates.some((state) => state.trim().toLowerCase() === normalizedState);

        if (!stillActive) {
          break;
        }

        turn += 1;
      }

      return {
        workspacePath: workspace.path,
        issue: currentIssue
      };
    } finally {
      abortSignal.removeEventListener("abort", onAbort);
      try {
        await this.workspace.runAfterRunHook(workspace.path, issue);
      } catch (error) {
        logger.warn("Failed running after_run hook", {
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          error: error instanceof Error ? error.message : String(error)
        });
      }

      await session.stop();
    }
  }
}
