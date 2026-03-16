defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Comment

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($id: String!, $body: String!) {
    commentUpdate(id: $id, input: {body: $body}) {
      success
    }
  }
  """

  @attach_github_pr_mutation """
  mutation SymphonyAttachGitHubPR($issueId: String!, $url: String!, $title: String) {
    attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, linkKind: links) {
      success
    }
  }
  """

  @attach_url_mutation """
  mutation SymphonyAttachURL($issueId: String!, $url: String!, $title: String) {
    attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
      success
    }
  }
  """

  @issue_query """
  query SymphonyIssue($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      state {
        name
      }
      branchName
      url
      assignee {
        id
      }
      labels {
        nodes {
          name
        }
      }
      inverseRelations(first: 50) {
        nodes {
          type
          issue {
            id
            identifier
            state {
              name
            }
          }
        }
      }
      createdAt
      updatedAt
    }
  }
  """

  @comments_query """
  query SymphonyIssueComments($id: String!) {
    issue(id: $id) {
      comments(first: 100) {
        nodes {
          id
          body
          url
          createdAt
          updatedAt
          user {
            id
            name
          }
        }
      }
    }
  }
  """

  @file_upload_mutation """
  mutation SymphonyFileUpload($filename: String!, $contentType: String!, $size: Int!) {
    fileUpload(filename: $filename, contentType: $contentType, size: $size) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        headers {
          key
          value
        }
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec get_issue(String.t()) :: {:ok, term()} | {:error, term()}
  def get_issue(issue_id_or_identifier) when is_binary(issue_id_or_identifier) do
    with {:ok, response} <- client_module().graphql(@issue_query, %{id: issue_id_or_identifier}),
         %{} = issue <- get_in(response, ["data", "issue"]),
         normalized_issue when not is_nil(normalized_issue) <- client_module().normalize_issue_for_test(issue) do
      {:ok, normalized_issue}
    else
      nil -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_not_found}
    end
  end

  @spec list_comments(String.t()) :: {:ok, [Comment.t()]} | {:error, term()}
  def list_comments(issue_id_or_identifier) when is_binary(issue_id_or_identifier) do
    case client_module().graphql(@comments_query, %{id: issue_id_or_identifier}) do
      {:ok, response} ->
        comments =
          response
          |> get_in(["data", "issue", "comments", "nodes"])
          |> List.wrap()
          |> Enum.map(&normalize_comment(&1, issue_id_or_identifier))
          |> Enum.reject(&is_nil/1)

        {:ok, comments}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_comment(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def update_comment(comment_id, body, _issue_id \\ nil)
      when is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@update_comment_mutation, %{id: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec attach_url(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_url(issue_id, url, title \\ nil)
      when is_binary(issue_id) and is_binary(url) do
    with {:ok, response} <-
           client_module().graphql(@attach_url_mutation, %{issueId: issue_id, url: url, title: title}),
         true <- get_in(response, ["data", "attachmentLinkURL", "success"]) == true do
      :ok
    else
      false -> {:error, :attachment_link_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :attachment_link_failed}
    end
  end

  @spec attach_pr(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_pr(issue_id, url, title \\ nil)
      when is_binary(issue_id) and is_binary(url) do
    with {:ok, response} <-
           client_module().graphql(@attach_github_pr_mutation, %{issueId: issue_id, url: url, title: title}),
         true <- get_in(response, ["data", "attachmentLinkGitHubPR", "success"]) == true do
      :ok
    else
      false -> {:error, :attachment_link_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :attachment_link_failed}
    end
  end

  @spec upload_attachment(String.t(), String.t(), String.t(), iodata()) :: {:ok, map()} | {:error, term()}
  def upload_attachment(_issue_id, filename, content_type, body)
      when is_binary(filename) and is_binary(content_type) do
    size = IO.iodata_length(body)

    with {:ok, response} <-
           client_module().graphql(@file_upload_mutation, %{
             filename: filename,
             contentType: content_type,
             size: size
           }),
         true <- get_in(response, ["data", "fileUpload", "success"]) == true,
         %{} = upload_file <- get_in(response, ["data", "fileUpload", "uploadFile"]),
         :ok <- upload_signed_file(upload_file, body, content_type) do
      {:ok,
       %{
         filename: filename,
         url: upload_file["assetUrl"],
         tracker_meta: upload_file
       }}
    else
      false -> {:error, :file_upload_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :file_upload_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp normalize_comment(comment, issue_id_or_identifier) when is_map(comment) do
    %Comment{
      id: comment["id"],
      issue_id: issue_id_or_identifier,
      body: comment["body"],
      url: comment["url"],
      author_id: get_in(comment, ["user", "id"]),
      author_name: get_in(comment, ["user", "name"]),
      created_at: parse_datetime(comment["createdAt"]),
      updated_at: parse_datetime(comment["updatedAt"]),
      tracker_meta: comment
    }
  end

  defp normalize_comment(_comment, _issue_id_or_identifier), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp upload_signed_file(%{"uploadUrl" => upload_url, "headers" => headers}, body, content_type)
       when is_binary(upload_url) and is_list(headers) do
    upload_headers =
      headers
      |> Enum.flat_map(fn
        %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) -> [{key, value}]
        _ -> []
      end)
      |> ensure_content_type_header(content_type)

    case Req.put(upload_url, headers: upload_headers, body: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:file_upload_status, status}}
      {:error, reason} -> {:error, {:file_upload_request, reason}}
    end
  end

  defp upload_signed_file(_upload_file, _body, _content_type), do: {:error, :file_upload_missing_url}

  defp ensure_content_type_header(headers, content_type) do
    if Enum.any?(headers, fn {key, _value} -> String.downcase(key) == "content-type" end) do
      headers
    else
      [{"Content-Type", content_type} | headers]
    end
  end
end
