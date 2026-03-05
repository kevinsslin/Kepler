import readline from "node:readline";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { logger } from "../logging/logger.js";
import type { Issue } from "../domain/types.js";
import type { ConfigStore } from "../config/config.js";
import { DynamicTools } from "./dynamicTools.js";

export interface CodexUpdate {
  event: string;
  timestamp: string;
  payload?: Record<string, unknown>;
  raw?: string;
  codex_app_server_pid?: string;
  usage?: Record<string, unknown>;
  rate_limits?: Record<string, unknown>;
  session_id?: string;
  thread_id?: string;
  turn_id?: string;
  message?: string;
}

type PendingRequest = {
  resolve: (value: Record<string, unknown>) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};
type RpcId = string | number;

interface TurnWaiter {
  resolve: (value: { sessionId: string; turnId: string }) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  turnId: string | null;
  sessionId: string | null;
  completedEarly: boolean;
}

export interface CodexSession {
  threadId: string;
  runTurn(prompt: string, issue: Issue, onUpdate: (update: CodexUpdate) => void): Promise<{ sessionId: string; turnId: string }>;
  stop(): Promise<void>;
  abortTurn(reason: string): void;
}

const INITIALIZE_ID = 1;
const THREAD_START_ID = 2;

interface RuntimeSettings {
  approvalPolicy: string | Record<string, unknown>;
  autoApproveRequests: boolean;
  threadSandbox: string;
  turnSandboxPolicy: Record<string, unknown>;
}

function nowIso(): string {
  return new Date().toISOString();
}

function asRpcId(value: unknown): RpcId | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string" && value.trim() !== "") {
    return value;
  }

  return null;
}

function rpcIdKey(id: RpcId): string {
  return String(id);
}

function asRecord(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }

  return {};
}

function extractUsage(payload: Record<string, unknown>): Record<string, unknown> | undefined {
  const usage = payload.usage;
  if (usage && typeof usage === "object" && !Array.isArray(usage)) {
    return usage as Record<string, unknown>;
  }

  const paramsUsage = asRecord(payload.params).usage;
  if (paramsUsage && typeof paramsUsage === "object" && !Array.isArray(paramsUsage)) {
    return paramsUsage as Record<string, unknown>;
  }

  return undefined;
}

function extractRateLimits(payload: Record<string, unknown>): Record<string, unknown> | undefined {
  const candidates = [payload.rateLimits, payload.rate_limits, asRecord(payload.params).rateLimits, asRecord(payload.params).rate_limits];

  for (const candidate of candidates) {
    if (candidate && typeof candidate === "object" && !Array.isArray(candidate)) {
      return candidate as Record<string, unknown>;
    }
  }

  return undefined;
}

class SessionHandle implements CodexSession {
  private readonly pending = new Map<string, PendingRequest>();

  private readonly lineReader: readline.Interface;

  private nextRequestId = 10;

  private turnWaiter: TurnWaiter | null = null;

  private closing = false;

  private runtime: RuntimeSettings | null = null;

  private turnUpdate: (update: CodexUpdate) => void = () => {};

  threadId = "";

  constructor(
    private readonly child: ChildProcessWithoutNullStreams,
    private readonly workspacePath: string,
    private readonly tools: DynamicTools,
    private readonly config: ConfigStore
  ) {
    this.lineReader = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    this.lineReader.on("line", (line) => {
      void this.handleLine(line);
    });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      const text = chunk.trim();
      if (!text) {
        return;
      }

      if (/\b(error|warn|warning|failed|fatal|panic|exception)\b/i.test(text)) {
        logger.warn("Codex stderr", { text: text.slice(0, 1000) });
      } else {
        logger.debug("Codex stderr", { text: text.slice(0, 1000) });
      }
    });

    child.on("exit", (code, signal) => {
      const reason = `codex_exit_${String(code)}_${String(signal)}`;
      this.failAllPending(new Error(reason));
      this.failTurn(new Error(reason));
    });

    child.on("error", (error) => {
      this.failAllPending(error);
      this.failTurn(error);
    });
  }

  async initialize(runtime: RuntimeSettings): Promise<void> {
    this.runtime = runtime;

    await this.request(
      INITIALIZE_ID,
      "initialize",
      {
        capabilities: {
          experimentalApi: true
        },
        clientInfo: {
          name: "symphony-orchestrator",
          title: "Symphony Orchestrator",
          version: "0.1.0"
        }
      },
      await this.config.codexReadTimeoutMs()
    );

    this.send({ method: "initialized", params: {} });

    const threadResult = await this.request(
      THREAD_START_ID,
      "thread/start",
      {
        approvalPolicy: runtime.approvalPolicy,
        sandbox: runtime.threadSandbox,
        cwd: this.workspacePath,
        dynamicTools: this.tools.specs()
      },
      await this.config.codexReadTimeoutMs()
    );

    const threadPayload = asRecord(threadResult.thread);
    const threadIdValue = asRpcId(threadPayload.id);
    if (threadIdValue == null) {
      throw new Error("invalid_thread_payload");
    }

    this.threadId = String(threadIdValue);
  }

  async runTurn(
    prompt: string,
    issue: Issue,
    onUpdate: (update: CodexUpdate) => void
  ): Promise<{ sessionId: string; turnId: string }> {
    if (!this.runtime) {
      throw new Error("session_not_initialized");
    }

    if (!this.threadId) {
      throw new Error("missing_thread_id");
    }

    const turnTimeoutMs = await this.config.codexTurnTimeoutMs();
    let turnId: string | null = null;
    let sessionId: string | null = null;

    const turnCompletion = new Promise<{ sessionId: string; turnId: string }>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.turnWaiter = null;
        reject(new Error("turn_timeout"));
      }, turnTimeoutMs);

      this.turnWaiter = {
        resolve,
        reject,
        timer,
        turnId: null,
        sessionId: null,
        completedEarly: false
      };
    });

    this.turnUpdate = (update: CodexUpdate): void => {
      onUpdate({
        ...update,
        session_id: update.session_id ?? sessionId ?? undefined,
        thread_id: update.thread_id ?? this.threadId,
        turn_id: update.turn_id ?? turnId ?? undefined,
        codex_app_server_pid: update.codex_app_server_pid ?? (this.child.pid ? String(this.child.pid) : undefined)
      });
    };

    try {
      const turnStartId = this.nextRequestId++;
      const turnResult = await this.request(
        turnStartId,
        "turn/start",
        {
          threadId: this.threadId,
          input: [{ type: "text", text: prompt }],
          cwd: this.workspacePath,
          title: `${issue.identifier}: ${issue.title}`,
          approvalPolicy: this.runtime.approvalPolicy,
          sandboxPolicy: this.runtime.turnSandboxPolicy
        },
        await this.config.codexReadTimeoutMs()
      );

      const turnPayload = asRecord(turnResult.turn);
      const turnIdValue = asRpcId(turnPayload.id);
      if (turnIdValue == null) {
        throw new Error("invalid_turn_payload");
      }
      turnId = String(turnIdValue);
      sessionId = `${this.threadId}-${turnId}`;

      onUpdate({
        event: "session_started",
        timestamp: nowIso(),
        session_id: sessionId,
        thread_id: this.threadId,
        turn_id: turnId,
        codex_app_server_pid: this.child.pid ? String(this.child.pid) : undefined
      });

      if (this.turnWaiter) {
        this.turnWaiter.turnId = turnId;
        this.turnWaiter.sessionId = sessionId;

        if (this.turnWaiter.completedEarly) {
          this.resolveTurn();
        }
      }
    } catch (error) {
      this.failTurn(error instanceof Error ? error : new Error(String(error)));
    }

    return await turnCompletion;
  }

  abortTurn(reason: string): void {
    this.failTurn(new Error(reason));
  }

  async stop(): Promise<void> {
    if (this.closing) {
      return;
    }

    this.closing = true;
    this.lineReader.close();

    this.failAllPending(new Error("session_stopped"));
    this.failTurn(new Error("session_stopped"));

    if (!this.child.killed) {
      this.child.kill("SIGTERM");
    }

    await new Promise<void>((resolve) => {
      const timeout = setTimeout(() => {
        if (!this.child.killed) {
          this.child.kill("SIGKILL");
        }
        resolve();
      }, 1_500);

      this.child.once("exit", () => {
        clearTimeout(timeout);
        resolve();
      });
    });
  }

  private async handleLine(line: string): Promise<void> {
    const payload = tryParse(line);
    if (!payload) {
      this.turnUpdate({
        event: "malformed",
        timestamp: nowIso(),
        raw: line
      });
      return;
    }

    const responseId = asRpcId(payload.id);
    if (responseId != null && this.pending.has(rpcIdKey(responseId))) {
      const key = rpcIdKey(responseId);
      const pending = this.pending.get(key)!;
      this.pending.delete(key);
      clearTimeout(pending.timer);

      if (payload.error) {
        pending.reject(new Error(`response_error:${JSON.stringify(payload.error)}`));
      } else {
        pending.resolve(asRecord(payload.result));
      }

      return;
    }

    if (typeof payload.method !== "string") {
      this.turnUpdate({
        event: "other_message",
        timestamp: nowIso(),
        payload,
        raw: line,
        usage: extractUsage(payload),
        rate_limits: extractRateLimits(payload)
      });
      return;
    }

    const method = payload.method;
    if (method === "turn/completed") {
      this.turnUpdate({
        event: "turn_completed",
        timestamp: nowIso(),
        payload,
        raw: line,
        usage: extractUsage(payload),
        rate_limits: extractRateLimits(payload)
      });

      this.resolveTurn();
      return;
    }

    if (method === "turn/failed") {
      this.turnUpdate({
        event: "turn_failed",
        timestamp: nowIso(),
        payload,
        raw: line,
        usage: extractUsage(payload),
        rate_limits: extractRateLimits(payload)
      });
      this.failTurn(new Error("turn_failed"));
      return;
    }

    if (method === "turn/cancelled") {
      this.turnUpdate({
        event: "turn_cancelled",
        timestamp: nowIso(),
        payload,
        raw: line,
        usage: extractUsage(payload),
        rate_limits: extractRateLimits(payload)
      });
      this.failTurn(new Error("turn_cancelled"));
      return;
    }

    await this.handleMethod(payload, line);
  }

  private async handleMethod(payload: Record<string, unknown>, raw: string): Promise<void> {
    const method = String(payload.method);

    if (!this.runtime) {
      return;
    }

    const approvalMethodToDecision: Record<string, string> = {
      "item/commandExecution/requestApproval": "acceptForSession",
      "item/fileChange/requestApproval": "acceptForSession",
      execCommandApproval: "approved_for_session",
      applyPatchApproval: "approved_for_session"
    };

    if (method in approvalMethodToDecision) {
      if (!this.runtime.autoApproveRequests) {
        this.turnUpdate({
          event: "approval_required",
          timestamp: nowIso(),
          payload,
          raw
        });
        this.failTurn(new Error("approval_required"));
        return;
      }

      const id = asRpcId(payload.id);
      if (id != null) {
        this.send({
          id,
          result: {
            decision: approvalMethodToDecision[method]
          }
        });
      } else {
        this.turnUpdate({
          event: "malformed",
          timestamp: nowIso(),
          payload,
          raw,
          message: "approval request missing id"
        });
        this.failTurn(new Error("approval_request_missing_id"));
        return;
      }

      this.turnUpdate({
        event: "approval_auto_approved",
        timestamp: nowIso(),
        payload,
        raw,
        message: approvalMethodToDecision[method]
      });
      return;
    }

    if (method === "item/tool/call") {
      const id = asRpcId(payload.id);
      const params = asRecord(payload.params);
      const tool = typeof params.tool === "string" ? params.tool : typeof params.name === "string" ? params.name : null;
      const args = params.arguments ?? {};
      const result = await this.tools.execute(tool, args);

      if (id != null) {
        this.send({ id, result });
      } else {
        this.turnUpdate({
          event: "malformed",
          timestamp: nowIso(),
          payload,
          raw,
          message: "tool call missing id"
        });
        this.failTurn(new Error("tool_call_missing_id"));
        return;
      }

      this.turnUpdate({
        event: result.success ? "tool_call_completed" : "tool_call_failed",
        timestamp: nowIso(),
        payload,
        raw,
        message: tool ?? "unknown_tool"
      });
      return;
    }

    if (
      method === "item/tool/requestUserInput" ||
      method === "turn/input_required" ||
      method === "turn/needs_input" ||
      method === "turn/approval_required"
    ) {
      this.turnUpdate({
        event: "turn_input_required",
        timestamp: nowIso(),
        payload,
        raw
      });
      this.failTurn(new Error("turn_input_required"));
      return;
    }

    this.turnUpdate({
      event: "notification",
      timestamp: nowIso(),
      payload,
      raw,
      usage: extractUsage(payload),
      rate_limits: extractRateLimits(payload)
    });
  }

  private resolveTurn(): void {
    if (!this.turnWaiter) {
      return;
    }

    const waiter = this.turnWaiter;

    if (!waiter.turnId || !waiter.sessionId) {
      waiter.completedEarly = true;
      return;
    }

    this.turnWaiter = null;
    clearTimeout(waiter.timer);
    waiter.resolve({
      sessionId: waiter.sessionId,
      turnId: waiter.turnId
    });
  }

  private failTurn(error: Error): void {
    if (!this.turnWaiter) {
      return;
    }

    const waiter = this.turnWaiter;
    this.turnWaiter = null;
    clearTimeout(waiter.timer);
    waiter.reject(error);
  }

  private failAllPending(error: Error): void {
    for (const [key, pending] of this.pending.entries()) {
      this.pending.delete(key);
      clearTimeout(pending.timer);
      pending.reject(error);
    }
  }

  private async request(
    id: RpcId,
    method: string,
    params: Record<string, unknown>,
    timeoutMs: number
  ): Promise<Record<string, unknown>> {
    const key = rpcIdKey(id);

    return await new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(key);
        reject(new Error("response_timeout"));
      }, timeoutMs);

      this.pending.set(key, { resolve, reject, timer });
      this.send({ id, method, params });
    });
  }

  private send(payload: Record<string, unknown>): void {
    this.child.stdin.write(`${JSON.stringify(payload)}\n`);
  }
}

function tryParse(line: string): Record<string, unknown> | null {
  try {
    const decoded = JSON.parse(line);
    if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
      return null;
    }

    return decoded as Record<string, unknown>;
  } catch {
    return null;
  }
}

export class CodexAppServerClient {
  constructor(private readonly config: ConfigStore, private readonly tools: DynamicTools) {}

  async startSession(workspacePath: string): Promise<CodexSession> {
    const command = await this.config.codexCommand();

    const child = spawn("bash", ["-lc", command], {
      cwd: workspacePath,
      stdio: ["pipe", "pipe", "pipe"]
    });

    child.stdin.setDefaultEncoding("utf8");

    const runtime = await this.config.codexRuntimeSettings(workspacePath);

    const handle = new SessionHandle(child, workspacePath, this.tools, this.config);

    try {
      await handle.initialize({
        approvalPolicy: runtime.approval_policy,
        autoApproveRequests: runtime.approval_policy === "never",
        threadSandbox: runtime.thread_sandbox,
        turnSandboxPolicy: runtime.turn_sandbox_policy
      });

      return handle;
    } catch (error) {
      await handle.stop();
      throw error;
    }
  }
}
