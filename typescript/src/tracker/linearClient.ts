import { ConfigStore } from "../config/config.js";
import type { BlockerRef, Issue } from "../domain/types.js";
import { logger } from "../logging/logger.js";

const ISSUE_PAGE_SIZE = 50;
const VIEWER_QUERY = `query SymphonyLinearViewer { viewer { id } }`;
const ISSUES_QUERY = `query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
  issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
    nodes {
      id
      identifier
      title
      description
      priority
      state { name }
      branchName
      url
      assignee { id }
      labels { nodes { name } }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue { id identifier state { name } }
        }
      }
      createdAt
      updatedAt
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}`;
const ISSUES_BY_IDS_QUERY = `query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!, $after: String) {
  issues(filter: {id: {in: $ids}}, first: $first, after: $after) {
    nodes {
      id
      identifier
      title
      description
      priority
      state { name }
      branchName
      url
      assignee { id }
      labels { nodes { name } }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue { id identifier state { name } }
        }
      }
      createdAt
      updatedAt
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}`;

interface GraphqlResponse<T> {
  data?: T;
  errors?: unknown;
}

export interface LinearGraphqlPayload extends Record<string, unknown> {
  data?: Record<string, unknown>;
  errors?: unknown;
}

interface LinearIssuesEnvelope {
  issues: {
    nodes: Record<string, unknown>[];
    pageInfo?: {
      hasNextPage?: boolean;
      endCursor?: string | null;
    };
  };
}

export class LinearClient {
  private viewerId: string | null = null;

  constructor(private readonly config: ConfigStore) {}

  async graphqlRaw(query: string, variables: Record<string, unknown> = {}): Promise<LinearGraphqlPayload> {
    const token = await this.config.linearApiToken();
    if (!token) {
      throw new Error("missing_linear_api_token");
    }

    const endpoint = await this.config.linearEndpoint();
    const requestTimeoutMs = await this.config.linearRequestTimeoutMs();
    const controller = new AbortController();
    const timer = setTimeout(() => {
      controller.abort();
    }, requestTimeoutMs);

    let response: Response;
    try {
      response = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: token,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          query,
          variables
        }),
        signal: controller.signal
      });
    } catch (error) {
      if (controller.signal.aborted) {
        throw new Error("linear_request_timeout");
      }
      throw error;
    } finally {
      clearTimeout(timer);
    }

    const decoded = (await response.json()) as GraphqlResponse<Record<string, unknown>> | unknown;
    const body =
      decoded && typeof decoded === "object" && !Array.isArray(decoded)
        ? (decoded as LinearGraphqlPayload)
        : ({} as LinearGraphqlPayload);

    if (!response.ok) {
      throw new Error(`linear_api_status_${response.status}`);
    }

    return body;
  }

  async graphql(query: string, variables: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const body = await this.graphqlRaw(query, variables);

    if (Array.isArray(body.errors) && body.errors.length > 0) {
      throw new Error("linear_graphql_errors");
    }

    return (body.data ?? {}) as Record<string, unknown>;
  }

  async fetchCandidateIssues(): Promise<Issue[]> {
    const projectSlug = await this.config.linearProjectSlug();
    if (!projectSlug) {
      throw new Error("missing_linear_project_slug");
    }

    const states = await this.config.linearActiveStates();
    const assigneeFilter = await this.resolveAssigneeFilter();

    return this.fetchByStates(projectSlug, states, assigneeFilter);
  }

  async fetchIssuesByStates(states: string[]): Promise<Issue[]> {
    const projectSlug = await this.config.linearProjectSlug();
    if (!projectSlug) {
      throw new Error("missing_linear_project_slug");
    }

    if (states.length === 0) {
      return [];
    }

    return this.fetchByStates(projectSlug, states, null);
  }

  async fetchIssueStatesByIds(ids: string[]): Promise<Issue[]> {
    if (ids.length === 0) {
      return [];
    }

    const seenIds = new Set<string>();
    const issuesById = new Map<string, Issue>();
    let after: string | null = null;

    while (true) {
      const data = (await this.graphql(ISSUES_BY_IDS_QUERY, {
        ids,
        first: ISSUE_PAGE_SIZE,
        relationFirst: ISSUE_PAGE_SIZE,
        after
      })) as {
        issues?: {
          nodes?: Record<string, unknown>[];
          pageInfo?: {
            hasNextPage?: boolean;
            endCursor?: string | null;
          };
        };
      };

      const nodes = data.issues?.nodes ?? [];
      for (const node of nodes) {
        const nodeId = asString(node.id);
        if (nodeId) {
          seenIds.add(nodeId);
        }

        const issue = normalizeIssue(node, null);
        if (issue) {
          issuesById.set(issue.id, issue);
        }
      }

      if (seenIds.size >= ids.length) {
        break;
      }

      const pageInfo = data.issues?.pageInfo;
      if (!pageInfo?.hasNextPage || !pageInfo.endCursor) {
        break;
      }

      after = pageInfo.endCursor;
    }

    return ids.map((id) => issuesById.get(id)).filter((issue): issue is Issue => issue != null);
  }

  async fetchTerminalIssues(): Promise<Issue[]> {
    const states = await this.config.linearTerminalStates();
    return this.fetchIssuesByStates(states);
  }

  private async fetchByStates(
    projectSlug: string,
    states: string[],
    assigneeFilter: string | null
  ): Promise<Issue[]> {
    const all: Issue[] = [];
    let after: string | null = null;

    while (true) {
      const data = (await this.graphql(ISSUES_QUERY, {
        projectSlug,
        stateNames: states,
        first: ISSUE_PAGE_SIZE,
        relationFirst: ISSUE_PAGE_SIZE,
        after
      })) as unknown as LinearIssuesEnvelope;

      const nodes = data.issues?.nodes ?? [];
      for (const node of nodes) {
        const issue = normalizeIssue(node, assigneeFilter);
        if (issue) {
          all.push(issue);
        }
      }

      const pageInfo = data.issues?.pageInfo;
      if (!pageInfo?.hasNextPage || !pageInfo.endCursor) {
        break;
      }

      after = pageInfo.endCursor;
    }

    return all;
  }

  private async resolveAssigneeFilter(): Promise<string | null> {
    const configured = await this.config.linearAssignee();
    if (!configured) {
      return null;
    }

    if (configured === "me") {
      if (this.viewerId) {
        return this.viewerId;
      }

      let data: { viewer?: { id?: string } };
      try {
        data = (await this.graphql(VIEWER_QUERY, {})) as { viewer?: { id?: string } };
      } catch (error) {
        logger.warn("Failed resolving Linear viewer id", { error });
        throw new Error("linear_viewer_lookup_failed");
      }

      this.viewerId = data.viewer?.id ?? null;
      if (!this.viewerId) {
        logger.warn("Linear viewer id missing for tracker.assignee=me");
        throw new Error("linear_viewer_lookup_failed");
      }

      return this.viewerId;
    }

    return configured;
  }
}

function normalizeIssue(node: Record<string, unknown>, assigneeFilter: string | null): Issue | null {
  const id = asString(node.id);
  const identifier = asString(node.identifier);
  const title = asString(node.title);
  const state = asString(asRecord(node.state).name);

  if (!id || !identifier || !title || !state) {
    return null;
  }

  const assigneeId = asString(asRecord(node.assignee).id);

  if (assigneeFilter && assigneeId !== assigneeFilter) {
    return null;
  }

  const labels = asArray(asRecord(node.labels).nodes)
    .map((entry) => asString(asRecord(entry).name))
    .filter((entry): entry is string => entry != null)
    .map((entry) => entry.toLowerCase());

  const blockedBy = normalizeBlockedBy(node.inverseRelations);

  return {
    id,
    identifier,
    title,
    description: asString(node.description),
    priority: asNumber(node.priority),
    state,
    branch_name: asString(node.branchName),
    url: asString(node.url),
    labels,
    blocked_by: blockedBy,
    assignee_id: assigneeId,
    created_at: asString(node.createdAt),
    updated_at: asString(node.updatedAt)
  };
}

function normalizeBlockedBy(raw: unknown): BlockerRef[] {
  const rels = asArray(asRecord(raw).nodes);
  const out: BlockerRef[] = [];

  for (const rel of rels) {
    const relRecord = asRecord(rel);
    const type = asString(relRecord.type);
    if (type !== "blocks") {
      continue;
    }

    const blockerIssue = asRecord(relRecord.issue);
    out.push({
      id: asString(blockerIssue.id),
      identifier: asString(blockerIssue.identifier),
      state: asString(asRecord(blockerIssue.state).name)
    });
  }

  return out;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }

  return {};
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function asString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function asNumber(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }

  return value;
}
