defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Comment

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback get_issue(String.t()) :: {:ok, term()} | {:error, term()}
  @callback list_comments(String.t()) :: {:ok, [Comment.t()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_comment(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback attach_url(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  @callback attach_pr(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  @callback upload_attachment(String.t(), String.t(), String.t(), iodata()) :: {:ok, map()} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec get_issue(String.t()) :: {:ok, term()} | {:error, term()}
  def get_issue(issue_id_or_identifier) do
    adapter().get_issue(issue_id_or_identifier)
  end

  @spec list_comments(String.t()) :: {:ok, [Comment.t()]} | {:error, term()}
  def list_comments(issue_id_or_identifier) do
    adapter().list_comments(issue_id_or_identifier)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_comment(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def update_comment(comment_id, body, issue_id \\ nil) do
    adapter().update_comment(comment_id, body, issue_id)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec attach_url(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_url(issue_id, url, title \\ nil) do
    adapter().attach_url(issue_id, url, title)
  end

  @spec attach_pr(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_pr(issue_id, url, title \\ nil) do
    adapter().attach_pr(issue_id, url, title)
  end

  @spec upload_attachment(String.t(), String.t(), String.t(), iodata()) :: {:ok, map()} | {:error, term()}
  def upload_attachment(issue_id, filename, content_type, body) do
    adapter().upload_attachment(issue_id, filename, content_type, body)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.tracker_kind() do
      "memory" -> SymphonyElixir.Tracker.Memory
      "jira" -> SymphonyElixir.Jira.Adapter
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
