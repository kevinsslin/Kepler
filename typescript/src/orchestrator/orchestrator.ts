import type {
  CodexTotals,
  Issue,
  IssueDebugSnapshot,
  RefreshResponse,
  RetryEntry,
  RunningEntry,
  Snapshot,
  Json
} from "../domain/types.js";
import { ConfigStore } from "../config/config.js";
import { logger } from "../logging/logger.js";
import { LinearClient } from "../tracker/linearClient.js";
import { WorkspaceManager } from "../workspace/manager.js";
import { AgentRunner } from "../agent/agentRunner.js";
import type { CodexUpdate } from "../agent/codexAppServerClient.js";
import { nextDelayWithBackoff } from "../utils/time.js";

const CONTINUATION_RETRY_DELAY_MS = 1_000;
const FAILURE_RETRY_BASE_MS = 10_000;
const FAILURE_RETRY_MAX_BACKOFF_FALLBACK_MS = 300_000;
const MAX_EVENTS_PER_ISSUE = 50;

interface RetryMetadata {
  identifier: string;
  error: string | null;
}

export class Orchestrator {
  private running = new Map<string, RunningEntry>();

  private claimed = new Set<string>();

  private retryAttempts = new Map<string, RetryEntry>();

  private completed = new Set<string>();

  private codexTotals: CodexTotals = {
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  };

  private codexRateLimits: Json | null = null;

  private pollTimer: ReturnType<typeof setTimeout> | null = null;

  private started = false;

  private pollCheckInProgress = false;

  private nextPollDueAtMs: number | null = null;

  private pollIntervalMs = 30_000;

  private maxConcurrentAgents = 10;

  private eventsByIssue = new Map<string, { at: string; event: string; message: string | null }[]>();

  private lastErrorByIssue = new Map<string, string>();

  private restartCountByIssue = new Map<string, number>();

  constructor(
    private readonly config: ConfigStore,
    private readonly tracker: LinearClient,
    private readonly workspace: WorkspaceManager,
    private readonly runner: AgentRunner
  ) {}

  async start(): Promise<void> {
    if (this.started) {
      return;
    }

    this.started = true;
    await this.refreshRuntimeConfig();
    await this.runTerminalWorkspaceCleanup();
    this.scheduleTick(0);
    logger.info("Orchestrator started", {
      poll_interval_ms: this.pollIntervalMs,
      max_concurrent_agents: this.maxConcurrentAgents
    });
  }

  async stop(): Promise<void> {
    this.started = false;

    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }

    for (const retry of this.retryAttempts.values()) {
      clearTimeout(retry.timer);
    }
    this.retryAttempts.clear();

    for (const entry of this.running.values()) {
      entry.abort();
    }

    await Promise.allSettled(Array.from(this.running.values()).map((entry) => entry.finished));
    this.running.clear();
    this.claimed.clear();

    logger.info("Orchestrator stopped");
  }

  snapshot(): Snapshot {
    const now = Date.now();

    const runningRows = Array.from(this.running.entries()).map(([issueId, entry]) => ({
      issue_id: issueId,
      issue_identifier: entry.issue.identifier,
      state: entry.issue.state,
      session_id: entry.session_id,
      turn_count: entry.turn_count,
      last_event: entry.last_codex_event,
      last_message: entry.last_codex_message,
      started_at: entry.started_at,
      last_event_at: entry.last_codex_timestamp,
      tokens: {
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }));

    const retryRows = Array.from(this.retryAttempts.values()).map((entry) => ({
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: new Date(entry.due_at_ms).toISOString(),
      error: entry.error
    }));

    const activeRuntimeSeconds = Array.from(this.running.values()).reduce((acc, entry) => {
      const startedMs = new Date(entry.started_at).getTime();
      if (Number.isNaN(startedMs)) {
        return acc;
      }

      return acc + Math.max(0, (now - startedMs) / 1000);
    }, 0);

    return {
      generated_at: new Date().toISOString(),
      counts: {
        running: runningRows.length,
        retrying: retryRows.length
      },
      running: runningRows,
      retrying: retryRows,
      codex_totals: {
        ...this.codexTotals,
        seconds_running: this.codexTotals.seconds_running + activeRuntimeSeconds
      },
      rate_limits: this.codexRateLimits,
      polling: {
        checking: this.pollCheckInProgress,
        next_poll_in_ms:
          this.nextPollDueAtMs == null ? null : Math.max(0, Math.floor(this.nextPollDueAtMs - Date.now())),
        poll_interval_ms: this.pollIntervalMs
      }
    };
  }

  issueSnapshot(issueIdentifier: string): IssueDebugSnapshot | null {
    const normalized = issueIdentifier.trim().toLowerCase();

    const runningEntry = Array.from(this.running.values()).find(
      (entry) => entry.issue.identifier.trim().toLowerCase() === normalized
    );

    const retryEntry = Array.from(this.retryAttempts.values()).find(
      (entry) => entry.identifier.trim().toLowerCase() === normalized
    );

    if (!runningEntry && !retryEntry) {
      return null;
    }

    const issueId = runningEntry?.issue.id ?? retryEntry?.issue_id ?? "";

    const runningRow = runningEntry
      ? {
          issue_id: runningEntry.issue.id,
          issue_identifier: runningEntry.issue.identifier,
          state: runningEntry.issue.state,
          session_id: runningEntry.session_id,
          turn_count: runningEntry.turn_count,
          last_event: runningEntry.last_codex_event,
          last_message: runningEntry.last_codex_message,
          started_at: runningEntry.started_at,
          last_event_at: runningEntry.last_codex_timestamp,
          tokens: {
            input_tokens: runningEntry.codex_input_tokens,
            output_tokens: runningEntry.codex_output_tokens,
            total_tokens: runningEntry.codex_total_tokens
          }
        }
      : null;

    return {
      issue_identifier: runningEntry?.issue.identifier ?? retryEntry?.identifier ?? issueIdentifier,
      issue_id: issueId,
      status: runningEntry ? "running" : retryEntry ? "retrying" : "idle",
      workspace: {
        path: runningEntry?.workspace_path ?? null
      },
      attempts: {
        restart_count: this.restartCountByIssue.get(issueId) ?? 0,
        current_retry_attempt: retryEntry?.attempt ?? null
      },
      running: runningRow,
      retry: retryEntry
        ? {
            attempt: retryEntry.attempt,
            due_at: new Date(retryEntry.due_at_ms).toISOString(),
            error: retryEntry.error
          }
        : null,
      logs: {
        codex_session_logs: []
      },
      recent_events: this.eventsByIssue.get(issueId) ?? [],
      last_error: this.lastErrorByIssue.get(issueId) ?? null,
      tracked: {}
    };
  }

  requestRefresh(): RefreshResponse {
    const now = Date.now();
    const alreadyDue = this.nextPollDueAtMs != null && this.nextPollDueAtMs <= now;
    const coalesced = this.pollCheckInProgress || alreadyDue;

    if (!coalesced) {
      this.scheduleTick(0);
    }

    return {
      queued: true,
      coalesced,
      requested_at: new Date().toISOString(),
      operations: ["poll", "reconcile"]
    };
  }

  private scheduleTick(delayMs: number): void {
    if (!this.started) {
      return;
    }

    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
    }

    this.nextPollDueAtMs = Date.now() + delayMs;
    this.pollTimer = setTimeout(() => {
      void this.tick();
    }, delayMs);
  }

  private async tick(): Promise<void> {
    if (!this.started) {
      return;
    }

    this.pollCheckInProgress = true;
    this.nextPollDueAtMs = null;

    try {
      await this.refreshRuntimeConfig();
      await this.reconcileRunningIssues();
      await this.maybeDispatch();
    } catch (error) {
      logger.error("Poll cycle failed", {
        error: error instanceof Error ? error.message : String(error)
      });
    } finally {
      this.pollCheckInProgress = false;
      this.scheduleTick(this.pollIntervalMs);
    }
  }

  private async refreshRuntimeConfig(): Promise<void> {
    await this.config.refresh();
    this.pollIntervalMs = await this.config.pollIntervalMs();
    this.maxConcurrentAgents = await this.config.maxConcurrentAgents();
  }

  private availableSlots(): number {
    return Math.max(0, this.maxConcurrentAgents - this.running.size);
  }

  private async maybeDispatch(): Promise<void> {
    const validationErrors = await this.config.validate();
    if (validationErrors.length > 0) {
      for (const error of validationErrors) {
        logger.error("Configuration validation error", {
          code: error.code,
          message: error.message
        });
      }
      return;
    }

    if (this.availableSlots() <= 0) {
      return;
    }

    const issues = await this.tracker.fetchCandidateIssues();
    const candidates = this.chooseIssues(issues);

    for (const issue of candidates) {
      if (this.availableSlots() <= 0) {
        break;
      }

      if (this.claimed.has(issue.id)) {
        continue;
      }

      if (!(await this.stateSlotsAvailable(issue))) {
        continue;
      }

      if (!(await this.todoBlockersEligible(issue))) {
        continue;
      }

      this.dispatchIssue(issue, null);
    }
  }

  private chooseIssues(issues: Issue[]): Issue[] {
    return issues
      .filter((issue) => !this.claimed.has(issue.id))
      .sort((a, b) => {
        const leftPriority = a.priority ?? Number.POSITIVE_INFINITY;
        const rightPriority = b.priority ?? Number.POSITIVE_INFINITY;
        if (leftPriority !== rightPriority) {
          return leftPriority - rightPriority;
        }

        const leftCreated = a.created_at ? new Date(a.created_at).getTime() : Number.POSITIVE_INFINITY;
        const rightCreated = b.created_at ? new Date(b.created_at).getTime() : Number.POSITIVE_INFINITY;
        if (leftCreated !== rightCreated) {
          return leftCreated - rightCreated;
        }

        return a.identifier.localeCompare(b.identifier);
      });
  }

  private async scheduleFailureRetry(issue: Issue, attempt: number, errorMessage: string): Promise<void> {
    let maxBackoffMs = FAILURE_RETRY_MAX_BACKOFF_FALLBACK_MS;

    try {
      maxBackoffMs = await this.config.maxRetryBackoffMs();
    } catch (error) {
      logger.warn("Using fallback max retry backoff after config read failure", {
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        error: error instanceof Error ? error.message : String(error),
        fallback_max_retry_backoff_ms: FAILURE_RETRY_MAX_BACKOFF_FALLBACK_MS
      });
    }

    const delay = nextDelayWithBackoff(FAILURE_RETRY_BASE_MS, attempt, maxBackoffMs);
    this.scheduleIssueRetry(issue.id, attempt, {
      identifier: issue.identifier,
      error: errorMessage
    }, delay);
  }

  private async stateSlotsAvailable(issue: Issue): Promise<boolean> {
    const limit = await this.config.maxConcurrentAgentsForState(issue.state);
    const normalized = issue.state.trim().toLowerCase();

    const inState = Array.from(this.running.values()).filter(
      (entry) => entry.issue.state.trim().toLowerCase() === normalized
    ).length;

    return inState < limit;
  }

  private dispatchIssue(issue: Issue, attempt: number | null): void {
    this.claimed.add(issue.id);

    const abortController = new AbortController();
    const startedAt = new Date().toISOString();

    const runningEntry: RunningEntry = {
      issue,
      started_at: startedAt,
      workspace_path: "",
      attempt,
      session_id: null,
      thread_id: null,
      turn_id: null,
      codex_app_server_pid: null,
      last_codex_event: null,
      last_codex_timestamp: startedAt,
      last_codex_message: null,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      last_reported_input_tokens: 0,
      last_reported_output_tokens: 0,
      last_reported_total_tokens: 0,
      turn_count: 0,
      abort: () => {
        abortController.abort();
      },
      finished: Promise.resolve()
    };

    this.running.set(issue.id, runningEntry);

    const finished = this.runner
      .run(
        issue,
        attempt,
        (update) => {
          this.handleCodexUpdate(issue.id, update);
        },
        abortController.signal
      )
      .then(async (result) => {
        const entry = this.running.get(issue.id);
        if (!entry) {
          return;
        }

        entry.workspace_path = result.workspacePath;

        const runtimeSeconds = Math.max(0, (Date.now() - new Date(entry.started_at).getTime()) / 1000);
        this.codexTotals.seconds_running += runtimeSeconds;

        this.running.delete(issue.id);
        this.completed.add(issue.id);
        this.restartCountByIssue.set(issue.id, (this.restartCountByIssue.get(issue.id) ?? 0) + 1);

        this.scheduleIssueRetry(issue.id, 1, {
          identifier: issue.identifier,
          error: null
        }, CONTINUATION_RETRY_DELAY_MS);
      })
      .catch((error) => {
        this.running.delete(issue.id);

        const message = error instanceof Error ? error.message : String(error);
        this.lastErrorByIssue.set(issue.id, message);
        logger.warn("Agent run failed", {
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          error: message
        });

        const nextAttempt = attempt == null ? 1 : attempt + 1;
        void this.scheduleFailureRetry(issue, nextAttempt, message);
      });

    runningEntry.finished = finished;
  }

  private scheduleIssueRetry(
    issueId: string,
    attempt: number,
    metadata: RetryMetadata,
    delayMs: number
  ): void {
    if (!this.started) {
      this.claimed.delete(issueId);
      return;
    }

    const current = this.retryAttempts.get(issueId);
    if (current) {
      clearTimeout(current.timer);
    }

    const dueAtMs = Date.now() + delayMs;

    const timer = setTimeout(() => {
      void this.handleRetryIssue(issueId, attempt, metadata);
    }, delayMs);

    this.retryAttempts.set(issueId, {
      issue_id: issueId,
      identifier: metadata.identifier,
      attempt,
      due_at_ms: dueAtMs,
      error: metadata.error,
      timer
    });
  }

  private async handleRetryIssue(issueId: string, attempt: number, metadata: RetryMetadata): Promise<void> {
    if (!this.started) {
      this.claimed.delete(issueId);
      return;
    }

    const entry = this.retryAttempts.get(issueId);
    if (!entry) {
      return;
    }

    this.retryAttempts.delete(issueId);

    if (this.running.has(issueId)) {
      this.scheduleIssueRetry(issueId, attempt, metadata, CONTINUATION_RETRY_DELAY_MS);
      return;
    }

    const issues = await this.tracker.fetchIssueStatesByIds([issueId]);
    const issue = issues[0];

    if (!issue) {
      this.claimed.delete(issueId);
      return;
    }

    const terminal = await this.isTerminalState(issue.state);
    if (terminal) {
      await this.workspace.removeIssueWorkspaces(issue.identifier);
      this.claimed.delete(issueId);
      return;
    }

    const active = await this.isActiveState(issue.state);
    if (!active) {
      this.claimed.delete(issueId);
      return;
    }

    if (!(await this.stateSlotsAvailable(issue)) || this.availableSlots() <= 0) {
      this.scheduleIssueRetry(issueId, attempt, {
        identifier: issue.identifier,
        error: "no available orchestrator slots"
      }, CONTINUATION_RETRY_DELAY_MS);
      return;
    }

    if (!(await this.todoBlockersEligible(issue))) {
      this.scheduleIssueRetry(issueId, attempt, {
        identifier: issue.identifier,
        error: "todo blockers not terminal"
      }, CONTINUATION_RETRY_DELAY_MS);
      return;
    }

    this.dispatchIssue(issue, attempt);
  }

  private async reconcileRunningIssues(): Promise<void> {
    await this.reconcileStalledRunningIssues();

    const runningIds = Array.from(this.running.keys());
    if (runningIds.length === 0) {
      return;
    }

    const refreshed = await this.tracker.fetchIssueStatesByIds(runningIds);
    const map = new Map(refreshed.map((issue) => [issue.id, issue]));

    for (const [issueId, runningEntry] of this.running.entries()) {
      const issue = map.get(issueId);
      if (!issue) {
        continue;
      }

      runningEntry.issue = issue;

      const terminal = await this.isTerminalState(issue.state);
      const active = await this.isActiveState(issue.state);

      if (terminal || !active) {
        runningEntry.abort();
        if (terminal) {
          await this.workspace.removeIssueWorkspaces(issue.identifier);
        }
        this.claimed.delete(issue.id);
      }
    }
  }

  private async reconcileStalledRunningIssues(): Promise<void> {
    const stallTimeoutMs = await this.config.codexStallTimeoutMs();
    if (stallTimeoutMs <= 0) {
      return;
    }

    const nowMs = Date.now();

    for (const [issueId, runningEntry] of this.running.entries()) {
      const lastActivityIso = runningEntry.last_codex_timestamp ?? runningEntry.started_at;
      const lastActivityMs = new Date(lastActivityIso).getTime();
      if (Number.isNaN(lastActivityMs)) {
        continue;
      }

      const idleMs = Math.max(0, nowMs - lastActivityMs);
      if (idleMs < stallTimeoutMs) {
        continue;
      }

      const reason = `codex_stall_timeout_${stallTimeoutMs}`;
      this.lastErrorByIssue.set(issueId, reason);

      logger.warn("Aborting stalled agent run", {
        issue_id: runningEntry.issue.id,
        issue_identifier: runningEntry.issue.identifier,
        stall_timeout_ms: stallTimeoutMs,
        idle_ms: idleMs
      });

      runningEntry.last_codex_event = "stall_timeout_abort";
      runningEntry.last_codex_timestamp = new Date(nowMs).toISOString();
      runningEntry.last_codex_message = reason;
      runningEntry.abort();
    }
  }

  private async runTerminalWorkspaceCleanup(): Promise<void> {
    try {
      const issues = await this.tracker.fetchTerminalIssues();
      for (const issue of issues) {
        await this.workspace.removeIssueWorkspaces(issue.identifier);
      }
    } catch (error) {
      logger.warn("Skipping startup terminal workspace cleanup", {
        error: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private async isActiveState(state: string): Promise<boolean> {
    const active = await this.config.linearActiveStates();
    const normalized = state.trim().toLowerCase();
    return active.some((item) => item.trim().toLowerCase() === normalized);
  }

  private async isTerminalState(state: string): Promise<boolean> {
    const terminal = await this.config.linearTerminalStates();
    const normalized = state.trim().toLowerCase();
    return terminal.some((item) => item.trim().toLowerCase() === normalized);
  }

  private async todoBlockersEligible(issue: Issue): Promise<boolean> {
    if (issue.state.trim().toLowerCase() !== "todo") {
      return true;
    }

    for (const blocker of issue.blocked_by) {
      const blockerState = blocker.state;
      if (!blockerState) {
        return false;
      }

      if (!(await this.isTerminalState(blockerState))) {
        return false;
      }
    }

    return true;
  }

  private handleCodexUpdate(issueId: string, update: CodexUpdate): void {
    const running = this.running.get(issueId);
    if (!running) {
      return;
    }

    running.last_codex_event = update.event;
    running.last_codex_timestamp = update.timestamp;
    running.last_codex_message = summarizeMessage(update);

    if (update.session_id) {
      if (running.session_id && update.session_id !== running.session_id) {
        running.turn_count += 1;
      } else if (!running.session_id) {
        running.turn_count = Math.max(1, running.turn_count);
      }

      running.session_id = update.session_id;
    }

    if (update.thread_id) {
      running.thread_id = update.thread_id;
    }

    if (update.turn_id) {
      running.turn_id = update.turn_id;
    }

    if (update.codex_app_server_pid) {
      running.codex_app_server_pid = update.codex_app_server_pid;
    }

    const tokens = extractTokenUsage(update);
    if (tokens) {
      applyTokenDelta(running, tokens, this.codexTotals);
    }

    if (update.rate_limits && typeof update.rate_limits === "object") {
      this.codexRateLimits = update.rate_limits as Json;
    }

    const queue = this.eventsByIssue.get(issueId) ?? [];
    queue.push({
      at: update.timestamp,
      event: update.event,
      message: summarizeMessage(update)
    });

    while (queue.length > MAX_EVENTS_PER_ISSUE) {
      queue.shift();
    }

    this.eventsByIssue.set(issueId, queue);
  }
}

function summarizeMessage(update: CodexUpdate): string | null {
  if (update.message) {
    return update.message;
  }

  if (update.payload) {
    const text = JSON.stringify(update.payload);
    return text.length <= 280 ? text : `${text.slice(0, 280)}...`;
  }

  if (update.raw) {
    return update.raw.length <= 280 ? update.raw : `${update.raw.slice(0, 280)}...`;
  }

  return null;
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }

  return null;
}

function extractTokenUsage(update: CodexUpdate):
  | {
      input: number;
      output: number;
      total: number;
    }
  | null {
  const roots: unknown[] = [update.usage, update.payload];

  for (const root of roots) {
    if (!root || typeof root !== "object") {
      continue;
    }

    const record = root as Record<string, unknown>;

    const totalTokenUsage = record.total_token_usage;
    if (totalTokenUsage && typeof totalTokenUsage === "object" && !Array.isArray(totalTokenUsage)) {
      const usageMap = totalTokenUsage as Record<string, unknown>;
      const input = asNumber(usageMap.input_tokens ?? usageMap.inputTokens) ?? 0;
      const output = asNumber(usageMap.output_tokens ?? usageMap.outputTokens) ?? 0;
      const total = asNumber(usageMap.total_tokens ?? usageMap.totalTokens) ?? input + output;
      return { input, output, total };
    }

    const input = asNumber(record.input_tokens ?? record.inputTokens ?? record.prompt_tokens);
    const output = asNumber(record.output_tokens ?? record.outputTokens ?? record.completion_tokens);
    const total = asNumber(record.total_tokens ?? record.totalTokens);

    if (input != null || output != null || total != null) {
      return {
        input: input ?? 0,
        output: output ?? 0,
        total: total ?? (input ?? 0) + (output ?? 0)
      };
    }
  }

  return null;
}

function applyTokenDelta(
  running: RunningEntry,
  usage: { input: number; output: number; total: number },
  totals: CodexTotals
): void {
  const inputDelta = Math.max(0, usage.input - running.last_reported_input_tokens);
  const outputDelta = Math.max(0, usage.output - running.last_reported_output_tokens);
  const totalDelta = Math.max(0, usage.total - running.last_reported_total_tokens);

  running.codex_input_tokens += inputDelta;
  running.codex_output_tokens += outputDelta;
  running.codex_total_tokens += totalDelta;

  running.last_reported_input_tokens = Math.max(running.last_reported_input_tokens, usage.input);
  running.last_reported_output_tokens = Math.max(running.last_reported_output_tokens, usage.output);
  running.last_reported_total_tokens = Math.max(running.last_reported_total_tokens, usage.total);

  totals.input_tokens += inputDelta;
  totals.output_tokens += outputDelta;
  totals.total_tokens += totalDelta;
}
