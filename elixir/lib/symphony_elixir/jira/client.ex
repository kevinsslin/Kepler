defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST client used by Symphony's Jira tracker adapter.
  """

  require Logger

  alias SymphonyElixir.{Config, Jira.Adf, Tracker.Comment, Tracker.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @issue_fields [
    "summary",
    "description",
    "priority",
    "status",
    "labels",
    "assignee",
    "created",
    "updated",
    "issuelinks"
  ]

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, assignee_clause} <- candidate_assignee_clause() do
      search_issues(build_candidate_jql(Config.jira_project_key(), assignee_clause, Config.tracker_active_states()))
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      _ ->
        search_issues(build_state_jql(Config.jira_project_key(), normalized_states))
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case get_issue(issue_id) do
        {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, :issue_not_found} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_issue(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def get_issue(issue_id_or_identifier) when is_binary(issue_id_or_identifier) do
    with {:ok, body} <-
           request(
             :get,
             "/rest/api/3/issue/#{URI.encode(issue_id_or_identifier)}",
             query: [fields: Enum.join(@issue_fields, ",")]
           ),
         %{} = issue <- normalize_issue(body) do
      {:ok, issue}
    else
      {:error, {:jira_api_status, 404}} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :jira_unknown_payload}
    end
  end

  @spec list_comments(String.t()) :: {:ok, [Comment.t()]} | {:error, term()}
  def list_comments(issue_id_or_identifier) when is_binary(issue_id_or_identifier) do
    with {:ok, body} <-
           request(:get, "/rest/api/3/issue/#{URI.encode(issue_id_or_identifier)}/comment", query: [maxResults: 100]) do
      comments =
        body
        |> Map.get("comments", [])
        |> Enum.map(&normalize_comment(&1, issue_id_or_identifier))
        |> Enum.reject(&is_nil/1)

      {:ok, comments}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id_or_identifier, body)
      when is_binary(issue_id_or_identifier) and is_binary(body) do
    case request(
           :post,
           "/rest/api/3/issue/#{URI.encode(issue_id_or_identifier)}/comment",
           json: %{"body" => Adf.from_text(body)}
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_comment(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def update_comment(comment_id, body, issue_id_or_identifier \\ nil)
      when is_binary(comment_id) and is_binary(body) do
    case issue_id_or_identifier do
      issue when is_binary(issue) and issue != "" ->
        path = "/rest/api/3/issue/#{URI.encode(issue)}/comment/#{URI.encode(comment_id)}"

        case request(:put, path, json: %{"body" => Adf.from_text(body)}) do
          {:ok, _response} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :jira_issue_id_required_for_comment_update}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id_or_identifier, state_name)
      when is_binary(issue_id_or_identifier) and is_binary(state_name) do
    with {:ok, transitions_body} <-
           request(:get, "/rest/api/3/issue/#{URI.encode(issue_id_or_identifier)}/transitions"),
         {:ok, transition_id} <- resolve_transition_id(transitions_body, state_name),
         {:ok, _response} <-
           request(
             :post,
             "/rest/api/3/issue/#{URI.encode(issue_id_or_identifier)}/transitions",
             json: %{"transition" => %{"id" => transition_id}}
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec attach_url(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_url(issue_id_or_identifier, url, title \\ nil)
      when is_binary(issue_id_or_identifier) and is_binary(url) do
    payload = %{
      "object" => %{
        "url" => url,
        "title" => title || url
      }
    }

    case request(:post, "/rest/api/3/issue/#{URI.encode(issue_id_or_identifier)}/remotelink", json: payload) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec attach_pr(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def attach_pr(issue_id_or_identifier, url, title \\ nil) do
    attach_url(issue_id_or_identifier, url, title)
  end

  @spec upload_attachment(String.t(), String.t(), String.t(), iodata()) :: {:ok, map()} | {:error, term()}
  def upload_attachment(issue_id_or_identifier, filename, content_type, body)
      when is_binary(issue_id_or_identifier) and is_binary(filename) and is_binary(content_type) do
    multipart = [file: {IO.iodata_to_binary(body), filename: filename, content_type: content_type}]

    with {:ok, response} <-
           request(
             :post,
             "/rest/api/3/issue/#{URI.encode(issue_id_or_identifier)}/attachments",
             headers: [{"X-Atlassian-Token", "no-check"}],
             form_multipart: multipart
           ),
         [%{} = attachment | _] <- response do
      {:ok,
       %{
         id: attachment["id"],
         filename: attachment["filename"],
         url: attachment["content"],
         tracker_meta: attachment
       }}
    else
      [] -> {:error, :jira_attachment_missing}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :jira_attachment_missing}
    end
  end

  @spec request(atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(method, path, opts \\ []) when is_atom(method) and is_binary(path) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
    headers = Keyword.get(opts, :headers, [])
    json_body = Keyword.get(opts, :json)
    form_multipart = Keyword.get(opts, :form_multipart)
    query = Keyword.get(opts, :query, [])

    req_options =
      []
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, build_url(path))
      |> Keyword.put(:headers, request_headers(headers, form_multipart))
      |> Keyword.put(:auth, {:basic, jira_basic_auth()})
      |> Keyword.put(:query, query)
      |> maybe_put_json(json_body)
      |> maybe_put_form_multipart(form_multipart)

    case request_fun.(req_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 429} = response} ->
        {:error, {:jira_rate_limited, retry_after_seconds(response), rate_limit_metadata(response)}}

      {:ok, %{status: status} = response} ->
        Logger.error("Jira REST request failed status=#{status} body=#{summarize_error_body(response.body)}")
        {:error, {:jira_api_status, status}}

      {:error, reason} ->
        Logger.error("Jira REST request failed: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  @doc false
  @spec build_candidate_jql_for_test(String.t(), String.t(), [String.t()]) :: String.t()
  def build_candidate_jql_for_test(project_key, assignee_clause, states) do
    build_candidate_jql(project_key, assignee_clause, states)
  end

  @doc false
  @spec build_state_jql_for_test(String.t(), [String.t()]) :: String.t()
  def build_state_jql_for_test(project_key, states) do
    build_state_jql(project_key, states)
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue), do: normalize_issue(issue)

  @doc false
  @spec normalize_comment_for_test(map(), String.t()) :: Comment.t() | nil
  def normalize_comment_for_test(comment, issue_id_or_identifier)
      when is_map(comment) and is_binary(issue_id_or_identifier) do
    normalize_comment(comment, issue_id_or_identifier)
  end

  @doc false
  @spec decode_search_response_for_test(map()) :: {:ok, [Issue.t()], integer() | nil} | {:error, term()}
  def decode_search_response_for_test(body) when is_map(body), do: decode_search_response(body)

  @doc false
  @spec resolve_transition_id_for_test(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_transition_id_for_test(body, state_name) when is_map(body) and is_binary(state_name) do
    resolve_transition_id(body, state_name)
  end

  defp search_issues(jql) when is_binary(jql) do
    paginate_search(jql, 0, [])
  end

  defp paginate_search(jql, start_at, acc) do
    with {:ok, body} <-
           request(
             :post,
             "/rest/api/3/search/jql",
             json: %{
               "jql" => jql,
               "startAt" => start_at,
               "maxResults" => @issue_page_size,
               "fields" => @issue_fields
             }
           ),
         {:ok, issues, next_start_at} <- decode_search_response(body) do
      updated = acc ++ issues

      case next_start_at do
        nil -> {:ok, updated}
        next_value -> paginate_search(jql, next_value, updated)
      end
    end
  end

  defp decode_search_response(%{"issues" => issues} = body) when is_list(issues) do
    normalized_issues =
      issues
      |> Enum.map(&normalize_issue/1)
      |> Enum.reject(&is_nil/1)

    total = Map.get(body, "total", length(normalized_issues))
    start_at = Map.get(body, "startAt", 0)
    max_results = Map.get(body, "maxResults", length(normalized_issues))
    next_start_at = if start_at + max_results < total, do: start_at + max_results, else: nil

    {:ok, normalized_issues, next_start_at}
  end

  defp decode_search_response(%{"values" => values} = body) when is_list(values) do
    decode_search_response(
      body
      |> Map.put("issues", values)
      |> Map.put_new("startAt", 0)
      |> Map.put_new("maxResults", length(values))
      |> Map.put_new("total", length(values))
    )
  end

  defp decode_search_response(_body), do: {:error, :jira_unknown_payload}

  defp normalize_issue(%{"fields" => fields} = issue) when is_map(fields) do
    status = fields["status"] || %{}
    assignee = fields["assignee"]
    status_name = get_in(status, ["name"])

    %Issue{
      id: issue["id"],
      identifier: issue["key"],
      title: fields["summary"],
      description: Adf.to_plain_text(fields["description"]),
      priority: normalize_priority(fields["priority"]),
      state: status_name,
      semantic_state: Config.semantic_state_for_tracker_state(status_name),
      branch_name: nil,
      url: issue_url(issue["key"]),
      assignee_id: assignee && assignee["accountId"],
      assignee_ref: assignee,
      blocked_by: extract_blockers(fields["issuelinks"]),
      labels: extract_labels(fields["labels"]),
      assigned_to_worker: assigned_to_worker?(assignee),
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"]),
      tracker_meta: %{
        "kind" => "jira",
        "status" => %{
          "id" => status["id"],
          "name" => status_name,
          "category" => get_in(status, ["statusCategory", "key"])
        }
      }
    }
  end

  defp normalize_issue(_issue), do: nil

  defp normalize_comment(comment, issue_id_or_identifier) when is_map(comment) do
    %Comment{
      id: comment["id"],
      issue_id: issue_id_or_identifier,
      body: Adf.to_plain_text(comment["body"]),
      url: comment["self"],
      author_id: get_in(comment, ["author", "accountId"]),
      author_name: get_in(comment, ["author", "displayName"]),
      created_at: parse_datetime(comment["created"]),
      updated_at: parse_datetime(comment["updated"]),
      tracker_meta: comment
    }
  end

  defp normalize_comment(_comment, _issue_id_or_identifier), do: nil

  defp candidate_assignee_clause do
    case Config.tracker_assignee() do
      nil -> {:ok, "currentUser()"}
      "me" -> {:ok, "currentUser()"}
      assignee when is_binary(assignee) -> {:ok, quote_jql_value(assignee)}
    end
  end

  defp build_candidate_jql(project_key, assignee_clause, states) do
    "project = #{quote_jql_value(project_key)} AND assignee = #{assignee_clause} AND status in (#{join_jql_values(states)}) ORDER BY created ASC"
  end

  defp build_state_jql(project_key, states) do
    "project = #{quote_jql_value(project_key)} AND status in (#{join_jql_values(states)}) ORDER BY created ASC"
  end

  defp quote_jql_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp join_jql_values(values) when is_list(values) do
    Enum.map_join(values, ", ", &quote_jql_value/1)
  end

  defp normalize_priority(%{"name" => name}) when is_binary(name) do
    case name |> String.trim() |> String.downcase() do
      "highest" -> 1
      "critical" -> 1
      "high" -> 2
      "medium" -> 3
      "low" -> 4
      "lowest" -> 4
      _ -> nil
    end
  end

  defp normalize_priority(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp normalize_priority(_value), do: nil

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_labels), do: []

  defp extract_blockers(issue_links) when is_list(issue_links) do
    inward_names =
      Config.jira_blocks_inward_link_names()
      |> Enum.map(&normalize_link_name/1)
      |> MapSet.new()

    issue_links
    |> Enum.flat_map(fn
      %{"type" => %{"inward" => inward}, "inwardIssue" => blocker_issue}
      when is_binary(inward) and is_map(blocker_issue) ->
        if MapSet.member?(inward_names, normalize_link_name(inward)) do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["key"],
              state: get_in(blocker_issue, ["fields", "status", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_issue_links), do: []

  defp normalize_link_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
  end

  defp assigned_to_worker?(nil), do: false

  defp assigned_to_worker?(%{"accountId" => account_id}) when is_binary(account_id) do
    case Config.tracker_assignee() do
      nil -> true
      "me" -> true
      assignee when is_binary(assignee) -> account_id == assignee
    end
  end

  defp assigned_to_worker?(_assignee), do: false

  defp issue_url(nil), do: nil

  defp issue_url(key) when is_binary(key) do
    String.trim_trailing(Config.jira_site_url() || "", "/") <> "/browse/#{key}"
  end

  defp resolve_transition_id(%{"transitions" => transitions}, state_name) when is_list(transitions) do
    normalized_target = normalize_issue_name(state_name)

    case Enum.find(transitions, fn
           %{"id" => _, "to" => %{"name" => name}} ->
             normalize_issue_name(name) == normalized_target

           _ ->
             false
         end) do
      %{"id" => transition_id} when is_binary(transition_id) -> {:ok, transition_id}
      _ -> {:error, :jira_transition_not_found}
    end
  end

  defp resolve_transition_id(_body, _state_name), do: {:error, :jira_transition_not_found}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_issue_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_name(_value), do: ""

  defp request_headers(headers, form_multipart) do
    base_headers =
      if is_nil(form_multipart) do
        [{"Content-Type", "application/json"}, {"Accept", "application/json"}]
      else
        [{"Accept", "application/json"}]
      end

    base_headers ++ headers
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, json_body), do: Keyword.put(opts, :json, json_body)

  defp maybe_put_form_multipart(opts, nil), do: opts
  defp maybe_put_form_multipart(opts, form_multipart), do: Keyword.put(opts, :form_multipart, form_multipart)

  defp default_request_fun(options) do
    Req.request(options)
  end

  defp build_url(path) do
    String.trim_trailing(Config.jira_site_url() || "", "/") <> path
  end

  defp jira_basic_auth do
    "#{Config.jira_auth_email()}:#{Config.jira_api_token()}"
  end

  defp retry_after_seconds(%{headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"retry-after", value} -> parse_integer(value)
      {"Retry-After", value} -> parse_integer(value)
      _ -> nil
    end)
  end

  defp retry_after_seconds(_response), do: nil

  defp rate_limit_metadata(%{headers: headers}) when is_list(headers) do
    headers
    |> Enum.filter(fn {key, _value} ->
      key
      |> to_string()
      |> String.downcase()
      |> String.starts_with?("x-ratelimit-")
    end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp rate_limit_metadata(_response), do: %{}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_integer(_value), do: nil

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
end
