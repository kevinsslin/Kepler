defmodule SymphonyElixir.Jira.Adapter do
  @moduledoc """
  Jira-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Jira.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec get_issue(String.t()) :: {:ok, term()} | {:error, term()}
  def get_issue(issue_id_or_identifier), do: client_module().get_issue(issue_id_or_identifier)

  @spec list_comments(String.t()) :: {:ok, [term()]} | {:error, term()}
  def list_comments(issue_id_or_identifier), do: client_module().list_comments(issue_id_or_identifier)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @spec update_comment(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def update_comment(comment_id, body, issue_id \\ nil), do: client_module().update_comment(comment_id, body, issue_id)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: client_module().update_issue_state(issue_id, state_name)

  @spec attach_url(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_url(issue_id, url, title \\ nil), do: client_module().attach_url(issue_id, url, title)

  @spec attach_pr(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_pr(issue_id, url, title \\ nil), do: client_module().attach_pr(issue_id, url, title)

  @spec upload_attachment(String.t(), String.t(), String.t(), iodata()) :: {:ok, map()} | {:error, term()}
  def upload_attachment(issue_id, filename, content_type, body),
    do: client_module().upload_attachment(issue_id, filename, content_type, body)

  defp client_module do
    Application.get_env(:symphony_elixir, :jira_client_module, Client)
  end
end
