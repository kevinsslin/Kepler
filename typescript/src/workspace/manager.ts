import fs from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import type { Issue, WorkspaceHooks, WorkspaceRecord } from "../domain/types.js";
import { ConfigStore } from "../config/config.js";
import { logger } from "../logging/logger.js";
import { isSubpath } from "../utils/paths.js";

export function sanitizeWorkspaceKey(identifier: string | null | undefined): string {
  const raw = identifier && identifier.trim() !== "" ? identifier : "issue";
  return raw.replace(/[^A-Za-z0-9._-]/g, "_");
}

interface HookResult {
  status: number;
  output: string;
}

export class WorkspaceManager {
  constructor(private readonly config: ConfigStore) {}

  async createForIssue(issue: Issue): Promise<WorkspaceRecord> {
    const root = await this.config.workspaceRoot();
    const key = sanitizeWorkspaceKey(issue.identifier);
    const workspacePath = path.join(root, key);

    await this.validateWorkspacePath(workspacePath);
    await fs.mkdir(root, { recursive: true });

    let createdNow = false;

    try {
      const stat = await fs.stat(workspacePath);
      if (!stat.isDirectory()) {
        await fs.rm(workspacePath, { recursive: true, force: true });
        await fs.mkdir(workspacePath, { recursive: true });
        createdNow = true;
      }
    } catch {
      await fs.mkdir(workspacePath, { recursive: true });
      createdNow = true;
    }

    const hooks = await this.config.workspaceHooks();
    if (createdNow && hooks.after_create) {
      await this.runHookOrThrow(hooks.after_create, workspacePath, issue, "after_create", hooks, true);
    }

    return {
      path: workspacePath,
      workspace_key: key,
      created_now: createdNow
    };
  }

  async runBeforeRunHook(workspacePath: string, issue: Issue): Promise<void> {
    const hooks = await this.config.workspaceHooks();
    if (!hooks.before_run) {
      return;
    }

    await this.runHookOrThrow(hooks.before_run, workspacePath, issue, "before_run", hooks, true);
  }

  async runAfterRunHook(workspacePath: string, issue: Issue): Promise<void> {
    const hooks = await this.config.workspaceHooks();
    if (!hooks.after_run) {
      return;
    }

    await this.runHookOrThrow(hooks.after_run, workspacePath, issue, "after_run", hooks, false);
  }

  async removeIssueWorkspaces(identifier: string): Promise<void> {
    const root = await this.config.workspaceRoot();
    const key = sanitizeWorkspaceKey(identifier);
    const workspacePath = path.join(root, key);

    await this.remove(workspacePath, key);
  }

  async remove(workspacePath: string, fallbackIdentifier = "issue"): Promise<void> {
    const hooks = await this.config.workspaceHooks();

    try {
      const stat = await fs.stat(workspacePath);
      if (!stat.isDirectory()) {
        await fs.rm(workspacePath, { recursive: true, force: true });
        return;
      }
    } catch {
      await fs.rm(workspacePath, { recursive: true, force: true });
      return;
    }

    await this.validateWorkspacePath(workspacePath);

    if (hooks.before_remove) {
      await this.runHookOrThrow(
        hooks.before_remove,
        workspacePath,
        {
          id: "",
          identifier: fallbackIdentifier,
          title: fallbackIdentifier,
          description: null,
          priority: null,
          state: "",
          branch_name: null,
          url: null,
          labels: [],
          blocked_by: [],
          assignee_id: null,
          created_at: null,
          updated_at: null
        },
        "before_remove",
        hooks,
        false
      );
    }

    await fs.rm(workspacePath, { recursive: true, force: true });
  }

  async validateWorkspacePath(workspacePath: string): Promise<void> {
    const root = await this.config.workspaceRoot();
    const resolvedRoot = path.resolve(root);
    const resolvedWorkspace = path.resolve(workspacePath);

    if (!isSubpath(resolvedRoot, resolvedWorkspace)) {
      throw new Error(
        `Workspace path must be under workspace root. workspace=${resolvedWorkspace} root=${resolvedRoot}`
      );
    }

    // Reject symlink escapes in existing path components.
    const relative = path.relative(resolvedRoot, resolvedWorkspace);
    const segments = relative.split(path.sep).filter((entry) => entry !== "");
    let current = resolvedRoot;

    for (const segment of segments) {
      current = path.join(current, segment);
      try {
        const stat = await fs.lstat(current);
        if (stat.isSymbolicLink()) {
          throw new Error(`Workspace path contains symlink segment: ${current}`);
        }
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code === "ENOENT") {
          return;
        }
        throw error;
      }
    }
  }

  private async runHookOrThrow(
    command: string,
    workspacePath: string,
    issue: Issue,
    hookName: keyof WorkspaceHooks,
    hooks: WorkspaceHooks,
    fatal: boolean
  ): Promise<void> {
    logger.info("Running workspace hook", {
      hook: hookName,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      workspace: workspacePath
    });

    try {
      const result = await this.runHook(command, workspacePath, hooks.timeout_ms);
      if (result.status !== 0) {
        const details = {
          hook: hookName,
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          workspace: workspacePath,
          status: result.status,
          output: truncateOutput(result.output)
        };

        if (fatal) {
          throw new Error(`Workspace hook failed: ${JSON.stringify(details)}`);
        }

        logger.warn("Workspace hook failed but ignored", details);
      }
    } catch (error) {
      if (fatal) {
        throw error;
      }

      logger.warn("Workspace hook error ignored", {
        hook: hookName,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        workspace: workspacePath,
        error: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private async runHook(command: string, cwd: string, timeoutMs: number): Promise<HookResult> {
    return new Promise<HookResult>((resolve, reject) => {
      const child = spawn("bash", ["-lc", command], {
        cwd,
        stdio: ["ignore", "pipe", "pipe"]
      });

      let output = "";
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error(`workspace_hook_timeout_${timeoutMs}`));
      }, timeoutMs);

      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => {
        output += chunk;
      });
      child.stderr.on("data", (chunk: string) => {
        output += chunk;
      });

      child.on("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });

      child.on("close", (status) => {
        clearTimeout(timer);
        resolve({ status: status ?? 1, output });
      });
    });
  }
}

function truncateOutput(value: string, maxBytes = 2048): string {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) {
    return value;
  }

  return `${value.slice(0, maxBytes)}... (truncated)`;
}
