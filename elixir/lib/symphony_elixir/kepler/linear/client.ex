defmodule SymphonyElixir.Kepler.Linear.Client do
  @moduledoc """
  Linear GraphQL client used by Kepler's hosted control plane.
  """

  require Logger

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Config.Schema
  alias SymphonyElixir.Kepler.Linear.Auth
  alias SymphonyElixir.Kepler.Linear.IssueContext

  @max_error_body_log_bytes 1_000

  @issue_query """
  query KeplerIssue($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      url
      branchName
      labels {
        nodes {
          name
        }
      }
      team {
        key
      }
      project {
        id
        slugId
      }
    }
  }
  """

  @repository_suggestions_query """
  query KeplerRepositorySuggestions($issueId: String!, $agentSessionId: String!, $candidateRepositories: [AgentRepositoryCandidateInput!]!) {
    issueRepositorySuggestions(
      issueId: $issueId
      agentSessionId: $agentSessionId
      candidateRepositories: $candidateRepositories
    ) {
      suggestions {
        repositoryFullName
        hostname
        confidence
      }
    }
  }
  """

  @activity_create_mutation """
  mutation KeplerAgentActivityCreate($input: AgentActivityCreateInput!) {
    agentActivityCreate(input: $input) {
      success
      agentActivity {
        id
      }
    }
  }
  """

  @session_update_mutation """
  mutation KeplerAgentSessionUpdate($agentSessionId: String!, $input: AgentSessionUpdateInput!) {
    agentSessionUpdate(id: $agentSessionId, input: $input) {
      success
    }
  }
  """

  @attachment_create_mutation """
  mutation KeplerAttachmentCreate($input: AttachmentCreateInput!) {
    attachmentCreate(input: $input) {
      success
      attachment {
        id
      }
    }
  }
  """

  @issue_state_lookup_query """
  query KeplerResolveStateId($issueId: String!, $stateName: String!) {
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

  @issue_update_state_mutation """
  mutation KeplerUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @comment_create_mutation """
  mutation KeplerCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
      }
    }
  }
  """

  @type repository_suggestion :: %{
          repository_full_name: String.t(),
          hostname: String.t() | nil,
          confidence: number() | nil
        }

  @spec fetch_issue(String.t()) :: {:ok, IssueContext.t()} | {:error, term()}
  def fetch_issue(issue_id) when is_binary(issue_id) do
    with {:ok, response} <- graphql(@issue_query, %{id: issue_id}),
         %{} = issue <- get_in(response, ["data", "issue"]) do
      {:ok, normalize_issue(issue)}
    else
      nil -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_not_found}
    end
  end

  @spec suggest_repositories(String.t(), String.t(), [map()]) ::
          {:ok, [repository_suggestion()]} | {:error, term()}
  def suggest_repositories(issue_id, agent_session_id, candidate_repositories)
      when is_binary(issue_id) and is_binary(agent_session_id) and is_list(candidate_repositories) do
    with {:ok, response} <-
           graphql(@repository_suggestions_query, %{
             issueId: issue_id,
             agentSessionId: agent_session_id,
             candidateRepositories: candidate_repositories
           }),
         suggestions when is_list(suggestions) <-
           get_in(response, ["data", "issueRepositorySuggestions", "suggestions"]) do
      {:ok,
       Enum.map(suggestions, fn suggestion ->
         %{
           repository_full_name: suggestion["repositoryFullName"],
           hostname: suggestion["hostname"],
           confidence: suggestion["confidence"]
         }
       end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:ok, []}
    end
  end

  @spec create_agent_activity(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def create_agent_activity(agent_session_id, content, opts \\ [])
      when is_binary(agent_session_id) and is_map(content) do
    input =
      %{
        agentSessionId: agent_session_id,
        content: content
      }
      |> maybe_put(:ephemeral, Keyword.get(opts, :ephemeral))

    with {:ok, response} <- graphql(@activity_create_mutation, %{input: input}),
         true <- get_in(response, ["data", "agentActivityCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :agent_activity_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_agent_session(String.t(), map()) :: :ok | {:error, term()}
  def update_agent_session(agent_session_id, input)
      when is_binary(agent_session_id) and is_map(input) do
    with {:ok, response} <-
           graphql(@session_update_mutation, %{agentSessionId: agent_session_id, input: input}),
         true <- get_in(response, ["data", "agentSessionUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :agent_session_update_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_issue_attachment(String.t(), map()) :: :ok | {:error, term()}
  def create_issue_attachment(issue_id, input)
      when is_binary(issue_id) and is_map(input) do
    payload =
      input
      |> Map.put(:issueId, issue_id)

    with {:ok, response} <- graphql(@attachment_create_mutation, %{input: payload}),
         true <- get_in(response, ["data", "attachmentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :attachment_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           graphql(@issue_update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec create_issue_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_issue_comment(issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- graphql(@comment_create_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    do_graphql(query, variables, opts, 0)
  end

  defp do_graphql(query, variables, opts, auth_retry_count) do
    payload =
      %{
        "query" => query,
        "variables" => variables
      }
      |> maybe_put("operationName", Keyword.get(opts, :operation_name))

    with {:ok, headers} <- headers(),
         {:ok, response} <- http_client_module().post(endpoint(), headers: headers, json: payload) do
      handle_graphql_response(query, variables, opts, auth_retry_count, response)
    else
      {:error, reason} ->
        Logger.error("Kepler Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  defp normalize_issue(issue) do
    %IssueContext{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      url: issue["url"],
      branch_name: issue["branchName"],
      labels: extract_labels(issue),
      team_key: get_in(issue, ["team", "key"]),
      project_id: get_in(issue, ["project", "id"]),
      project_slug: get_in(issue, ["project", "slugId"])
    }
  end

  defp extract_labels(issue) do
    issue
    |> get_in(["labels", "nodes"])
    |> case do
      nodes when is_list(nodes) ->
        nodes
        |> Enum.map(&Map.get(&1, "name"))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp endpoint do
    Config.settings!().linear.endpoint
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           graphql(@issue_state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp headers do
    Auth.headers()
  end

  defp handle_graphql_response(_query, _variables, _opts, _auth_retry_count, %{status: 200, body: %{"errors" => errors} = body})
       when is_list(errors) and errors != [] do
    Logger.error("Kepler Linear GraphQL request returned errors=#{summarize_graphql_errors(errors)} body=#{summarize_error_body(body)}")
    {:error, {:linear_graphql_errors, normalize_graphql_errors(errors)}}
  end

  defp handle_graphql_response(_query, _variables, _opts, _auth_retry_count, %{status: 200, body: body}) do
    {:ok, body}
  end

  defp handle_graphql_response(query, variables, opts, auth_retry_count, %{status: 401, body: body})
       when auth_retry_count == 0 do
    if Schema.linear_auth_mode(Config.settings!().linear) == :client_credentials do
      Logger.warning("Kepler Linear GraphQL request returned 401; invalidating client credentials token and retrying once")
      Auth.invalidate_token()
      do_graphql(query, variables, opts, auth_retry_count + 1)
    else
      Logger.error("Kepler Linear GraphQL request failed status=401 body=#{summarize_error_body(body)}")
      {:error, {:linear_api_status, 401}}
    end
  end

  defp handle_graphql_response(_query, _variables, _opts, _auth_retry_count, response) do
    Logger.error("Kepler Linear GraphQL request failed status=#{response.status} body=#{summarize_error_body(response.body)}")
    {:error, {:linear_api_status, response.status}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_graphql_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{"message" => message} when is_binary(message) -> message
      %{"message" => message} -> to_string(message)
      other -> inspect(other)
    end)
  end

  defp summarize_graphql_errors(errors) do
    errors
    |> normalize_graphql_errors()
    |> Enum.join(" | ")
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp http_client_module do
    Application.get_env(:symphony_elixir, :kepler_linear_http_client_module, Req)
  end
end
