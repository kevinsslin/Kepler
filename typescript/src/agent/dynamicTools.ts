import { parse, Kind } from "graphql";
import { ConfigStore } from "../config/config.js";
import { LinearClient, type LinearGraphqlPayload } from "../tracker/linearClient.js";

const LINEAR_GRAPHQL = "linear_graphql";

export interface ToolResult {
  success: boolean;
  contentItems: {
    type: "inputText";
    text: string;
  }[];
}

function encodePayload(payload: unknown): string {
  return JSON.stringify(payload, null, 2);
}

function failure(payload: Record<string, unknown>): ToolResult {
  return {
    success: false,
    contentItems: [{ type: "inputText", text: encodePayload(payload) }]
  };
}

function success(payload: Record<string, unknown>): ToolResult {
  return {
    success: true,
    contentItems: [{ type: "inputText", text: encodePayload(payload) }]
  };
}

function normalizeToolInput(argumentsPayload: unknown): { query: string; variables: Record<string, unknown> } {
  if (typeof argumentsPayload === "string") {
    const query = argumentsPayload.trim();
    if (!query) {
      throw new Error("missing_query");
    }

    return { query, variables: {} };
  }

  if (!argumentsPayload || typeof argumentsPayload !== "object" || Array.isArray(argumentsPayload)) {
    throw new Error("invalid_arguments");
  }

  const map = argumentsPayload as Record<string, unknown>;
  const query = typeof map.query === "string" ? map.query.trim() : "";
  if (!query) {
    throw new Error("missing_query");
  }

  const variables = map.variables ?? {};
  if (!variables || typeof variables !== "object" || Array.isArray(variables)) {
    throw new Error("invalid_variables");
  }

  return {
    query,
    variables: variables as Record<string, unknown>
  };
}

function validateSingleOperation(query: string): void {
  const parsed = parse(query);
  const operations = parsed.definitions.filter((def) => def.kind === Kind.OPERATION_DEFINITION);

  if (operations.length !== 1) {
    throw new Error("multiple_operations");
  }
}

export class DynamicTools {
  constructor(private readonly config: ConfigStore, private readonly linearClient: LinearClient) {}

  specs(): Record<string, unknown>[] {
    return [
      {
        name: LINEAR_GRAPHQL,
        description: "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.",
        inputSchema: {
          type: "object",
          additionalProperties: false,
          required: ["query"],
          properties: {
            query: {
              type: "string",
              description: "GraphQL query or mutation document to execute against Linear."
            },
            variables: {
              type: ["object", "null"],
              description: "Optional GraphQL variables object.",
              additionalProperties: true
            }
          }
        }
      }
    ];
  }

  async execute(toolName: string | null | undefined, argumentsPayload: unknown): Promise<ToolResult> {
    if (toolName !== LINEAR_GRAPHQL) {
      return failure({
        error: {
          message: `Unsupported dynamic tool: ${String(toolName)}.`,
          supportedTools: [LINEAR_GRAPHQL]
        }
      });
    }

    try {
      const trackerKind = await this.config.trackerKind();
      if (trackerKind !== "linear") {
        return failure({
          error: {
            message: "`linear_graphql` is only available when tracker.kind is linear."
          }
        });
      }

      const { query, variables } = normalizeToolInput(argumentsPayload);
      validateSingleOperation(query);

      const response = (await this.linearClient.graphqlRaw(query, variables)) as LinearGraphqlPayload;
      const hasErrors = Array.isArray(response.errors) && response.errors.length > 0;
      if (hasErrors) {
        return failure(response as Record<string, unknown>);
      }

      return success(response as Record<string, unknown>);
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);

      if (reason === "missing_query") {
        return failure({
          error: {
            message: "`linear_graphql` requires a non-empty `query` string."
          }
        });
      }

      if (reason === "invalid_arguments") {
        return failure({
          error: {
            message:
              "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
          }
        });
      }

      if (reason === "invalid_variables") {
        return failure({
          error: {
            message: "`linear_graphql.variables` must be a JSON object when provided."
          }
        });
      }

      if (reason === "multiple_operations") {
        return failure({
          error: {
            message: "`linear_graphql.query` must contain exactly one operation."
          }
        });
      }

      return failure({
        error: {
          message: "Linear GraphQL tool execution failed.",
          reason
        }
      });
    }
  }
}
