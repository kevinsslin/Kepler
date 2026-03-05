import path from "node:path";
import os from "node:os";
import type { CodexRuntimeSettings, WorkflowDefinition, WorkspaceHooks } from "../domain/types.js";
import { logger } from "../logging/logger.js";
import { loadWorkflowFile, workflowMtimeMs } from "../workflow/loader.js";
import { expandEnvRef, expandHome, isSubpath, normalizePath } from "../utils/paths.js";

const DEFAULT_ACTIVE_STATES = ["Todo", "In Progress"];
const DEFAULT_TERMINAL_STATES = ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"];
const DEFAULT_LINEAR_ENDPOINT = "https://api.linear.app/graphql";
const DEFAULT_LINEAR_REQUEST_TIMEOUT_MS = 15_000;
const DEFAULT_PROMPT_TEMPLATE = `You are working on a Linear issue.\n\nIdentifier: {{ issue.identifier }}\nTitle: {{ issue.title }}\n\nBody:\n{% if issue.description %}\n{{ issue.description }}\n{% else %}\nNo description provided.\n{% endif %}`;
const DEFAULT_POLL_INTERVAL_MS = 30_000;
const DEFAULT_WORKSPACE_ROOT = path.join(os.tmpdir(), "symphony_workspaces");
const DEFAULT_HOOK_TIMEOUT_MS = 60_000;
const DEFAULT_MAX_CONCURRENT_AGENTS = 10;
const DEFAULT_AGENT_MAX_TURNS = 20;
const DEFAULT_MAX_RETRY_BACKOFF_MS = 300_000;
const DEFAULT_CODEX_COMMAND = "codex app-server";
const DEFAULT_CODEX_TURN_TIMEOUT_MS = 3_600_000;
const DEFAULT_CODEX_READ_TIMEOUT_MS = 5_000;
const DEFAULT_CODEX_STALL_TIMEOUT_MS = 300_000;
const DEFAULT_APPROVAL_POLICY: Record<string, unknown> = {
  reject: {
    sandbox_approval: true,
    rules: true,
    mcp_elicitations: true
  }
};
const DEFAULT_THREAD_SANDBOX = "workspace-write";
const DEFAULT_OBSERVABILITY_ENABLED = true;
const DEFAULT_OBSERVABILITY_REFRESH_MS = 1_000;
const DEFAULT_SERVER_HOST = "127.0.0.1";

export interface ConfigValidationError {
  code: string;
  message: string;
}

function asObject(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }

  return {};
}

function asString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function asStringList(value: unknown, fallback: string[]): string[] {
  if (!Array.isArray(value)) {
    return fallback;
  }

  const out = value
    .map((item) => (typeof item === "string" ? item.trim() : ""))
    .filter((item) => item !== "");

  return out.length > 0 ? out : fallback;
}

function asPositiveInt(value: unknown, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  const out = Math.floor(value);
  return out > 0 ? out : fallback;
}

function asNonNegativeInt(value: unknown, fallback: number | null): number | null {
  if (value == null) {
    return fallback;
  }

  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  const out = Math.floor(value);
  return out >= 0 ? out : fallback;
}

function resolveSecret(value: string | null | undefined, fallbackEnv?: string): string | null {
  const fallback = fallbackEnv ? process.env[fallbackEnv] ?? null : null;
  const resolved = expandEnvRef(value ?? null, fallback);
  return resolved && resolved.trim() !== "" ? resolved : null;
}

function defaultTurnSandboxPolicy(workspacePath: string | null): Record<string, unknown> {
  const base = workspacePath ? path.resolve(workspacePath) : undefined;

  return {
    type: "workspaceWrite",
    ...(base
      ? {
          writableRoots: [base]
        }
      : {})
  };
}

function normalizePrompt(template: string): string {
  return template.trim() === "" ? DEFAULT_PROMPT_TEMPLATE : template;
}

export class ConfigStore {
  private workflow: WorkflowDefinition | null = null;

  private workflowMtime: number | null = null;

  constructor(private workflowPath: string) {}

  setWorkflowPath(nextPath: string): void {
    this.workflowPath = path.resolve(nextPath);
    this.workflow = null;
    this.workflowMtime = null;
  }

  getWorkflowPath(): string {
    return path.resolve(this.workflowPath);
  }

  async refresh(): Promise<void> {
    const mtime = await workflowMtimeMs(this.workflowPath);

    if (this.workflow && this.workflowMtime != null && this.workflowMtime === mtime) {
      return;
    }

    this.workflow = await loadWorkflowFile(this.workflowPath);
    this.workflowMtime = mtime;
    logger.info("Loaded workflow configuration", { workflow_path: this.getWorkflowPath() });
  }

  async currentWorkflow(): Promise<WorkflowDefinition> {
    await this.refresh();
    if (!this.workflow) {
      throw new Error("Workflow unavailable after refresh.");
    }

    return this.workflow;
  }

  private section(name: string): Record<string, unknown> {
    if (!this.workflow) {
      throw new Error("Workflow is not loaded.");
    }

    return asObject(this.workflow.config[name]);
  }

  async trackerKind(): Promise<string | null> {
    await this.refresh();
    return asString(this.section("tracker").kind);
  }

  async linearEndpoint(): Promise<string> {
    await this.refresh();
    return asString(this.section("tracker").endpoint) ?? DEFAULT_LINEAR_ENDPOINT;
  }

  async linearRequestTimeoutMs(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("tracker").request_timeout_ms, DEFAULT_LINEAR_REQUEST_TIMEOUT_MS);
  }

  async linearApiToken(): Promise<string | null> {
    await this.refresh();
    return resolveSecret(asString(this.section("tracker").api_key), "LINEAR_API_KEY");
  }

  async linearProjectSlug(): Promise<string | null> {
    await this.refresh();
    return asString(this.section("tracker").project_slug);
  }

  async linearAssignee(): Promise<string | null> {
    await this.refresh();
    return resolveSecret(asString(this.section("tracker").assignee), "LINEAR_ASSIGNEE");
  }

  async linearActiveStates(): Promise<string[]> {
    await this.refresh();
    return asStringList(this.section("tracker").active_states, DEFAULT_ACTIVE_STATES);
  }

  async linearTerminalStates(): Promise<string[]> {
    await this.refresh();
    return asStringList(this.section("tracker").terminal_states, DEFAULT_TERMINAL_STATES);
  }

  async pollIntervalMs(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("polling").interval_ms, DEFAULT_POLL_INTERVAL_MS);
  }

  async workspaceRoot(): Promise<string> {
    await this.refresh();
    const raw = asString(this.section("workspace").root);
    const resolved = expandEnvRef(raw, DEFAULT_WORKSPACE_ROOT) ?? DEFAULT_WORKSPACE_ROOT;
    return normalizePath(expandHome(resolved));
  }

  async workspaceHooks(): Promise<WorkspaceHooks> {
    await this.refresh();
    const hooks = this.section("hooks");

    return {
      after_create: asString(hooks.after_create),
      before_run: asString(hooks.before_run),
      after_run: asString(hooks.after_run),
      before_remove: asString(hooks.before_remove),
      timeout_ms: asPositiveInt(hooks.timeout_ms, DEFAULT_HOOK_TIMEOUT_MS)
    };
  }

  async maxConcurrentAgents(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("agent").max_concurrent_agents, DEFAULT_MAX_CONCURRENT_AGENTS);
  }

  async maxConcurrentAgentsByState(): Promise<Map<string, number>> {
    await this.refresh();
    const raw = asObject(this.section("agent").max_concurrent_agents_by_state);
    const map = new Map<string, number>();

    for (const [state, value] of Object.entries(raw)) {
      const limit = asPositiveInt(value, 0);
      if (limit > 0) {
        map.set(state.trim().toLowerCase(), limit);
      }
    }

    return map;
  }

  async maxConcurrentAgentsForState(stateName: string): Promise<number> {
    const stateLimits = await this.maxConcurrentAgentsByState();
    const fallback = await this.maxConcurrentAgents();
    return stateLimits.get(stateName.trim().toLowerCase()) ?? fallback;
  }

  async agentMaxTurns(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("agent").max_turns, DEFAULT_AGENT_MAX_TURNS);
  }

  async maxRetryBackoffMs(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("agent").max_retry_backoff_ms, DEFAULT_MAX_RETRY_BACKOFF_MS);
  }

  async codexCommand(): Promise<string> {
    await this.refresh();
    return asString(this.section("codex").command) ?? DEFAULT_CODEX_COMMAND;
  }

  async codexTurnTimeoutMs(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("codex").turn_timeout_ms, DEFAULT_CODEX_TURN_TIMEOUT_MS);
  }

  async codexReadTimeoutMs(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("codex").read_timeout_ms, DEFAULT_CODEX_READ_TIMEOUT_MS);
  }

  async codexStallTimeoutMs(): Promise<number> {
    await this.refresh();
    return asNonNegativeInt(this.section("codex").stall_timeout_ms, DEFAULT_CODEX_STALL_TIMEOUT_MS) ??
      DEFAULT_CODEX_STALL_TIMEOUT_MS;
  }

  async codexApprovalPolicy(): Promise<string | Record<string, unknown>> {
    await this.refresh();
    const policy = this.section("codex").approval_policy;

    if (typeof policy === "string" && policy.trim() !== "") {
      return policy.trim();
    }

    if (policy && typeof policy === "object" && !Array.isArray(policy)) {
      return policy as Record<string, unknown>;
    }

    return DEFAULT_APPROVAL_POLICY;
  }

  async codexThreadSandbox(): Promise<string> {
    await this.refresh();
    return asString(this.section("codex").thread_sandbox) ?? DEFAULT_THREAD_SANDBOX;
  }

  async codexTurnSandboxPolicy(workspacePath: string | null): Promise<Record<string, unknown>> {
    await this.refresh();
    const policy = this.section("codex").turn_sandbox_policy;

    if (policy && typeof policy === "object" && !Array.isArray(policy)) {
      const asMap = policy as Record<string, unknown>;
      if (typeof asMap.type === "string" && asMap.type.trim() !== "") {
        return asMap;
      }
    }

    return defaultTurnSandboxPolicy(workspacePath);
  }

  async codexRuntimeSettings(workspacePath: string | null): Promise<CodexRuntimeSettings> {
    return {
      approval_policy: await this.codexApprovalPolicy(),
      thread_sandbox: await this.codexThreadSandbox(),
      turn_sandbox_policy: await this.codexTurnSandboxPolicy(workspacePath)
    };
  }

  async observabilityEnabled(): Promise<boolean> {
    await this.refresh();
    const value = this.section("observability").dashboard_enabled;
    return typeof value === "boolean" ? value : DEFAULT_OBSERVABILITY_ENABLED;
  }

  async observabilityRefreshMs(): Promise<number> {
    await this.refresh();
    return asPositiveInt(this.section("observability").refresh_ms, DEFAULT_OBSERVABILITY_REFRESH_MS);
  }

  async serverPort(): Promise<number | null> {
    await this.refresh();
    return asNonNegativeInt(this.section("server").port, null);
  }

  async serverHost(): Promise<string> {
    await this.refresh();
    return asString(this.section("server").host) ?? DEFAULT_SERVER_HOST;
  }

  async workflowPromptTemplate(): Promise<string> {
    const wf = await this.currentWorkflow();
    return normalizePrompt(wf.prompt_template);
  }

  async validate(workspacePathForSandbox?: string | null): Promise<ConfigValidationError[]> {
    const errors: ConfigValidationError[] = [];

    const trackerKind = await this.trackerKind();
    if (!trackerKind) {
      errors.push({ code: "missing_tracker_kind", message: "tracker.kind is required." });
    } else if (trackerKind !== "linear") {
      errors.push({ code: "unsupported_tracker_kind", message: `Unsupported tracker.kind: ${trackerKind}` });
    }

    if (!(await this.linearApiToken())) {
      errors.push({ code: "missing_linear_api_token", message: "Linear API token is missing." });
    }

    if (!(await this.linearProjectSlug())) {
      errors.push({ code: "missing_linear_project_slug", message: "Linear project slug is missing." });
    }

    if (!(await this.codexCommand())) {
      errors.push({ code: "missing_codex_command", message: "codex.command is required." });
    }

    const workspaceRoot = await this.workspaceRoot();
    if (!path.isAbsolute(workspaceRoot)) {
      errors.push({ code: "workspace_root_not_absolute", message: "workspace.root must resolve to an absolute path." });
    }

    if (workspacePathForSandbox) {
      const absoluteWorkspace = path.resolve(workspacePathForSandbox);
      if (!isSubpath(workspaceRoot, absoluteWorkspace)) {
        errors.push({
          code: "workspace_outside_root",
          message: `Workspace path ${absoluteWorkspace} must stay under root ${workspaceRoot}.`
        });
      }
    }

    return errors;
  }
}
