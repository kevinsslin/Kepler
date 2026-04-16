defmodule SymphonyElixir.Kepler.Run do
  @moduledoc """
  Durable run record stored by the Kepler control plane.
  """

  @derive Jason.Encoder

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: String.t(),
          linear_issue_id: String.t(),
          linear_issue_identifier: String.t() | nil,
          linear_issue_title: String.t() | nil,
          linear_issue_description: String.t() | nil,
          linear_issue_url: String.t() | nil,
          linear_agent_session_id: String.t(),
          repository_id: String.t() | nil,
          repository_candidates: [String.t()],
          routing_source: String.t() | nil,
          routing_reason: String.t() | nil,
          provider: String.t(),
          workspace_path: String.t() | nil,
          github_installation_id: integer() | nil,
          branch: String.t() | nil,
          pr_url: String.t() | nil,
          status: status(),
          prompt_context: String.t() | nil,
          follow_up_prompts: [String.t()],
          active_follow_up_prompts: [String.t()],
          issue_labels: [String.t()],
          issue_team_key: String.t() | nil,
          issue_project_id: String.t() | nil,
          issue_project_slug: String.t() | nil,
          worklog_comment_id: String.t() | nil,
          runtime_plan: String.t() | nil,
          tool_calls: [String.t()],
          tool_call_count: non_neg_integer(),
          final_agent_message: String.t() | nil,
          last_error: String.t() | nil,
          summary: String.t() | nil,
          created_at: String.t(),
          updated_at: String.t()
        }

  defstruct [
    :id,
    :linear_issue_id,
    :linear_issue_identifier,
    :linear_issue_title,
    :linear_issue_description,
    :linear_issue_url,
    :linear_agent_session_id,
    :repository_id,
    repository_candidates: [],
    routing_source: nil,
    routing_reason: nil,
    provider: "codex",
    workspace_path: nil,
    github_installation_id: nil,
    branch: nil,
    pr_url: nil,
    status: "pending",
    prompt_context: nil,
    follow_up_prompts: [],
    active_follow_up_prompts: [],
    issue_labels: [],
    issue_team_key: nil,
    issue_project_id: nil,
    issue_project_slug: nil,
    worklog_comment_id: nil,
    runtime_plan: nil,
    tool_calls: [],
    tool_call_count: 0,
    final_agent_message: nil,
    last_error: nil,
    summary: nil,
    created_at: nil,
    updated_at: nil
  ]

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    attrs
    |> Map.put_new(:id, default_run_id())
    |> Map.put_new(:created_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&struct!(__MODULE__, &1))
  end

  @spec touch(t(), map()) :: t()
  def touch(%__MODULE__{} = run, attrs) when is_map(attrs) do
    updated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    struct!(run, Map.put(attrs, :updated_at, updated_at))
  end

  @spec interrupted?(t()) :: boolean()
  def interrupted?(%__MODULE__{status: status}) do
    status in ["queued", "preparing_workspace", "executing", "publishing"]
  end

  @spec recoverable?(t()) :: boolean()
  def recoverable?(%__MODULE__{repository_id: repository_id} = run) do
    interrupted?(run) and is_binary(repository_id) and repository_id != ""
  end

  defp default_run_id do
    "run-" <> Ecto.UUID.generate()
  end
end
