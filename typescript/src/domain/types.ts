export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export interface BlockerRef {
  id: string | null;
  identifier: string | null;
  state: string | null;
}

export interface Issue {
  id: string;
  identifier: string;
  title: string;
  description: string | null;
  priority: number | null;
  state: string;
  branch_name: string | null;
  url: string | null;
  labels: string[];
  blocked_by: BlockerRef[];
  assignee_id: string | null;
  created_at: string | null;
  updated_at: string | null;
}

export interface WorkflowDefinition {
  config: Record<string, unknown>;
  prompt_template: string;
  prompt: string;
}

export interface WorkspaceRecord {
  path: string;
  workspace_key: string;
  created_now: boolean;
}

export interface CodexTotals {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  seconds_running: number;
}

export interface RetryEntry {
  issue_id: string;
  identifier: string;
  attempt: number;
  due_at_ms: number;
  error: string | null;
  timer: Timer;
}

export interface LiveSession {
  session_id: string | null;
  thread_id: string | null;
  turn_id: string | null;
  codex_app_server_pid: string | null;
  last_codex_event: string | null;
  last_codex_timestamp: string | null;
  last_codex_message: string | null;
  codex_input_tokens: number;
  codex_output_tokens: number;
  codex_total_tokens: number;
  last_reported_input_tokens: number;
  last_reported_output_tokens: number;
  last_reported_total_tokens: number;
  turn_count: number;
}

export interface RunningEntry extends LiveSession {
  issue: Issue;
  started_at: string;
  workspace_path: string;
  attempt: number | null;
  abort: () => void;
  finished: Promise<void>;
}

export interface SnapshotRow {
  issue_id: string;
  issue_identifier: string;
  state: string;
  session_id: string | null;
  turn_count: number;
  last_event: string | null;
  last_message: string | null;
  started_at: string;
  last_event_at: string | null;
  tokens: {
    input_tokens: number;
    output_tokens: number;
    total_tokens: number;
  };
}

export interface Snapshot {
  generated_at: string;
  counts: {
    running: number;
    retrying: number;
  };
  running: SnapshotRow[];
  retrying: {
    issue_id: string;
    issue_identifier: string;
    attempt: number;
    due_at: string;
    error: string | null;
  }[];
  codex_totals: CodexTotals;
  rate_limits: Json | null;
  polling: {
    checking: boolean;
    next_poll_in_ms: number | null;
    poll_interval_ms: number;
  };
}

export interface IssueDebugSnapshot {
  issue_identifier: string;
  issue_id: string;
  status: "running" | "retrying" | "idle";
  workspace: {
    path: string | null;
  };
  attempts: {
    restart_count: number;
    current_retry_attempt: number | null;
  };
  running: SnapshotRow | null;
  retry: {
    attempt: number;
    due_at: string;
    error: string | null;
  } | null;
  logs: {
    codex_session_logs: {
      label: string;
      path: string;
      url: string | null;
    }[];
  };
  recent_events: {
    at: string;
    event: string;
    message: string | null;
  }[];
  last_error: string | null;
  tracked: Record<string, Json>;
}

export interface RefreshResponse {
  queued: true;
  coalesced: boolean;
  requested_at: string;
  operations: ["poll", "reconcile"];
}

export interface WorkspaceHooks {
  after_create: string | null;
  before_run: string | null;
  after_run: string | null;
  before_remove: string | null;
  timeout_ms: number;
}

export interface CodexRuntimeSettings {
  approval_policy: string | Record<string, unknown>;
  thread_sandbox: string;
  turn_sandbox_policy: Record<string, unknown>;
}
