#!/usr/bin/env bun
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { ConfigStore } from "./config/config.js";
import { logger } from "./logging/logger.js";
import { LinearClient } from "./tracker/linearClient.js";
import { WorkspaceManager } from "./workspace/manager.js";
import { PromptBuilder } from "./prompt/promptBuilder.js";
import { DynamicTools } from "./agent/dynamicTools.js";
import { CodexAppServerClient } from "./agent/codexAppServerClient.js";
import { AgentRunner } from "./agent/agentRunner.js";
import { Orchestrator } from "./orchestrator/orchestrator.js";
import { HttpServer } from "./http/server.js";

const ACK_SWITCH = "--i-understand-that-this-will-be-running-without-the-usual-guardrails";

interface ParsedArgs {
  workflowPath: string;
  logsRoot: string | null;
  port: number | null;
  acknowledged: boolean;
}

function usage(): string {
  return "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]";
}

function acknowledgementBanner(): string {
  const lines = [
    "This Symphony implementation is a low key engineering preview.",
    "Codex may run with permissive policy settings based on your WORKFLOW.md.",
    "Symphony TypeScript is experimental and presented as-is.",
    `To proceed, start with ${ACK_SWITCH}`
  ];

  const width = Math.max(...lines.map((line) => line.length));
  const border = "─".repeat(width + 2);
  const top = `╭${border}╮`;
  const bottom = `╰${border}╯`;
  const spacer = `│ ${" ".repeat(width)} │`;

  const content = [
    top,
    spacer,
    ...lines.map((line) => `│ ${line.padEnd(width, " ")} │`),
    spacer,
    bottom
  ];

  return content.join("\n");
}

function parseArgs(argv: string[]): ParsedArgs {
  const args = [...argv];
  let workflowPath = path.resolve("WORKFLOW.md");
  let logsRoot: string | null = null;
  let port: number | null = null;
  let acknowledged = false;

  while (args.length > 0) {
    const arg = args.shift()!;

    if (arg === ACK_SWITCH) {
      acknowledged = true;
      continue;
    }

    if (arg === "--logs-root") {
      const value = args.shift();
      if (!value) {
        throw new Error(usage());
      }
      logsRoot = path.resolve(value);
      continue;
    }

    if (arg === "--port") {
      const value = args.shift();
      if (!value) {
        throw new Error(usage());
      }

      const parsed = Number(value);
      if (!Number.isInteger(parsed) || parsed < 0) {
        throw new Error(usage());
      }

      port = parsed;
      continue;
    }

    if (arg.startsWith("--")) {
      throw new Error(usage());
    }

    workflowPath = path.resolve(arg);
  }

  return {
    workflowPath,
    logsRoot,
    port,
    acknowledged
  };
}

async function run(): Promise<void> {
  const parsed = parseArgs(process.argv.slice(2));

  if (!parsed.acknowledged) {
    console.error(acknowledgementBanner());
    process.exit(1);
  }

  if (!fs.existsSync(parsed.workflowPath)) {
    console.error(`Workflow file not found: ${parsed.workflowPath}`);
    process.exit(1);
  }

  if (parsed.logsRoot) {
    fs.mkdirSync(parsed.logsRoot, { recursive: true });
    process.env.SYMPHONY_LOGS_ROOT = parsed.logsRoot;
  }

  const config = new ConfigStore(parsed.workflowPath);
  await config.refresh();

  const tracker = new LinearClient(config);
  const workspace = new WorkspaceManager(config);
  const promptBuilder = new PromptBuilder(config);
  const tools = new DynamicTools(config, tracker);
  const codex = new CodexAppServerClient(config, tools);
  const runner = new AgentRunner(config, workspace, promptBuilder, tracker, codex);
  const orchestrator = new Orchestrator(config, tracker, workspace, runner);

  let server: HttpServer | null = null;

  const configuredPort = parsed.port ?? (await config.serverPort());
  if (configuredPort != null) {
    const host = await config.serverHost();
    server = new HttpServer(orchestrator, host, configuredPort);
    server.start();
  }

  await orchestrator.start();

  const shutdown = async (signal: string): Promise<void> => {
    logger.info("Received shutdown signal", { signal });
    server?.stop();
    await orchestrator.stop();
    process.exit(0);
  };

  process.on("SIGINT", () => {
    void shutdown("SIGINT");
  });

  process.on("SIGTERM", () => {
    void shutdown("SIGTERM");
  });
}

void run().catch((error) => {
  logger.error("Failed to start Symphony TypeScript", {
    error: error instanceof Error ? error.message : String(error)
  });
  process.exit(1);
});
