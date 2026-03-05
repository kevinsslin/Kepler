import { logger } from "../logging/logger.js";
import { Orchestrator } from "../orchestrator/orchestrator.js";

export class HttpServer {
  private server: ReturnType<typeof Bun.serve> | null = null;

  constructor(
    private readonly orchestrator: Orchestrator,
    private readonly host: string,
    private readonly port: number
  ) {}

  start(): void {
    this.server = Bun.serve({
      hostname: this.host,
      port: this.port,
      fetch: async (request) => {
        return await this.route(request);
      }
    });

    logger.info("HTTP observability server started", {
      host: this.host,
      port: this.server.port
    });
  }

  stop(): void {
    this.server?.stop();
    this.server = null;
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      if (request.method !== "GET") {
        return methodNotAllowed();
      }

      const snapshot = this.orchestrator.snapshot();
      const html = renderDashboard(snapshot);
      return new Response(html, {
        status: 200,
        headers: {
          "Content-Type": "text/html; charset=utf-8"
        }
      });
    }

    if (url.pathname === "/api/v1/state") {
      if (request.method !== "GET") {
        return methodNotAllowed();
      }

      return json(200, this.orchestrator.snapshot());
    }

    if (url.pathname === "/api/v1/refresh") {
      if (request.method !== "POST") {
        return methodNotAllowed();
      }

      const response = this.orchestrator.requestRefresh();
      return json(202, response);
    }

    if (url.pathname.startsWith("/api/v1/")) {
      if (request.method !== "GET") {
        return methodNotAllowed();
      }

      const identifier = decodeURIComponent(url.pathname.replace("/api/v1/", "")).trim();
      if (!identifier) {
        return errorResponse(404, "issue_not_found", "Issue identifier was empty.");
      }

      const payload = this.orchestrator.issueSnapshot(identifier);
      if (!payload) {
        return errorResponse(404, "issue_not_found", `Issue ${identifier} is unknown to runtime state.`);
      }

      return json(200, payload);
    }

    return errorResponse(404, "not_found", "Route not found.");
  }
}

function json(status: number, payload: unknown): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8"
    }
  });
}

function errorResponse(status: number, code: string, message: string): Response {
  return json(status, {
    error: {
      code,
      message
    }
  });
}

function methodNotAllowed(): Response {
  return errorResponse(405, "method_not_allowed", "Method Not Allowed");
}

function renderDashboard(snapshot: ReturnType<Orchestrator["snapshot"]>): string {
  const pretty = JSON.stringify(snapshot, null, 2);
  return `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Symphony Observability</title>
    <style>
      body { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace; margin: 16px; background: #0b1220; color: #dbe7ff; }
      h1 { font-size: 18px; margin: 0 0 12px; }
      .meta { margin: 0 0 12px; color: #9cb0d8; }
      pre { background: #101a32; padding: 16px; border-radius: 8px; overflow: auto; }
      a { color: #8ecbff; }
    </style>
  </head>
  <body>
    <h1>Symphony Runtime Snapshot</h1>
    <p class="meta">Refresh endpoint: <code>POST /api/v1/refresh</code> | API state: <a href="/api/v1/state">/api/v1/state</a></p>
    <pre>${escapeHtml(pretty)}</pre>
  </body>
</html>`;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}
