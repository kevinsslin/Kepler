defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Jira.Client, Tracker}

  @linear_graphql_tool "linear_graphql"
  @jira_rest_tool "jira_rest"
  @tracker_get_issue_tool "tracker_get_issue"
  @tracker_list_comments_tool "tracker_list_comments"
  @tracker_create_comment_tool "tracker_create_comment"
  @tracker_update_comment_tool "tracker_update_comment"
  @tracker_transition_issue_tool "tracker_transition_issue"
  @tracker_attach_pr_tool "tracker_attach_pr"
  @tracker_attach_url_tool "tracker_attach_url"
  @tracker_upload_attachment_tool "tracker_upload_attachment"

  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """

  @jira_rest_description """
  Execute an allowlisted Jira Cloud REST request against Symphony's configured Jira site.
  """

  @tracker_get_issue_description "Fetch a normalized tracker issue by id or identifier."
  @tracker_list_comments_description "List normalized comments for a tracker issue."
  @tracker_create_comment_description "Create a tracker comment on an issue."
  @tracker_update_comment_description "Update an existing tracker comment."
  @tracker_transition_issue_description "Move a tracker issue to a target tracker state or semantic state."
  @tracker_attach_pr_description "Attach a pull request URL to a tracker issue."
  @tracker_attach_url_description "Attach a generic URL to a tracker issue."
  @tracker_upload_attachment_description "Upload a local file as a tracker attachment."

  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @jira_rest_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{"type" => "string"},
      "path" => %{"type" => "string"},
      "query" => %{"type" => ["object", "null"], "additionalProperties" => true},
      "body" => %{"type" => ["object", "null"], "additionalProperties" => true}
    }
  }

  @issue_lookup_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueId"],
    "properties" => %{
      "issueId" => %{"type" => "string"}
    }
  }

  @comment_create_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueId", "body"],
    "properties" => %{
      "issueId" => %{"type" => "string"},
      "body" => %{"type" => "string"}
    }
  }

  @comment_update_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["commentId", "body"],
    "properties" => %{
      "commentId" => %{"type" => "string"},
      "issueId" => %{"type" => ["string", "null"]},
      "body" => %{"type" => "string"}
    }
  }

  @transition_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueId"],
    "properties" => %{
      "issueId" => %{"type" => "string"},
      "state" => %{"type" => ["string", "null"]},
      "semanticState" => %{"type" => ["string", "null"]}
    }
  }

  @attachment_link_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueId", "url"],
    "properties" => %{
      "issueId" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "title" => %{"type" => ["string", "null"]}
    }
  }

  @attachment_upload_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueId", "path"],
    "properties" => %{
      "issueId" => %{"type" => "string"},
      "path" => %{"type" => "string"},
      "filename" => %{"type" => ["string", "null"]},
      "contentType" => %{"type" => ["string", "null"]}
    }
  }

  @spec execute(String.t() | nil, term()) :: map()
  def execute(tool, arguments), do: execute(tool, arguments, [])

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@linear_graphql_tool, arguments, opts), do: execute_linear_graphql(arguments, opts)
  def execute(@jira_rest_tool, arguments, opts), do: execute_jira_rest(arguments, opts)
  def execute(@tracker_get_issue_tool, arguments, opts), do: execute_tracker_get_issue(arguments, opts)
  def execute(@tracker_list_comments_tool, arguments, opts), do: execute_tracker_list_comments(arguments, opts)
  def execute(@tracker_create_comment_tool, arguments, opts), do: execute_tracker_create_comment(arguments, opts)
  def execute(@tracker_update_comment_tool, arguments, opts), do: execute_tracker_update_comment(arguments, opts)
  def execute(@tracker_transition_issue_tool, arguments, opts), do: execute_tracker_transition_issue(arguments, opts)
  def execute(@tracker_attach_pr_tool, arguments, opts), do: execute_tracker_attach_pr(arguments, opts)
  def execute(@tracker_attach_url_tool, arguments, opts), do: execute_tracker_attach_url(arguments, opts)
  def execute(@tracker_upload_attachment_tool, arguments, opts), do: execute_tracker_upload_attachment(arguments, opts)

  def execute(other, _arguments, _opts) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(other)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      tool_spec(@linear_graphql_tool, @linear_graphql_description, @linear_graphql_input_schema),
      tool_spec(@jira_rest_tool, @jira_rest_description, @jira_rest_input_schema),
      tool_spec(@tracker_get_issue_tool, @tracker_get_issue_description, @issue_lookup_input_schema),
      tool_spec(@tracker_list_comments_tool, @tracker_list_comments_description, @issue_lookup_input_schema),
      tool_spec(@tracker_create_comment_tool, @tracker_create_comment_description, @comment_create_input_schema),
      tool_spec(@tracker_update_comment_tool, @tracker_update_comment_description, @comment_update_input_schema),
      tool_spec(@tracker_transition_issue_tool, @tracker_transition_issue_description, @transition_input_schema),
      tool_spec(@tracker_attach_pr_tool, @tracker_attach_pr_description, @attachment_link_input_schema),
      tool_spec(@tracker_attach_url_tool, @tracker_attach_url_description, @attachment_link_input_schema),
      tool_spec(
        @tracker_upload_attachment_tool,
        @tracker_upload_attachment_description,
        @attachment_upload_input_schema
      )
    ]
  end

  defp tool_spec(name, description, input_schema) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => input_schema
    }
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &SymphonyElixir.Linear.Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(linear_tool_error_payload(reason))
    end
  end

  defp execute_jira_rest(arguments, opts) do
    jira_client = Keyword.get(opts, :jira_client, &Client.request/3)

    with {:ok, method, path, request_opts} <- normalize_jira_rest_arguments(arguments),
         :ok <- validate_jira_rest_path(method, path, request_opts),
         {:ok, response} <- jira_client.(method, path, request_opts) do
      success_response(%{"data" => response})
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_get_issue(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    with {:ok, issue_id} <- required_string_argument(arguments, "issueId"),
         {:ok, issue} <- tracker_module.get_issue(issue_id) do
      success_response(%{"issue" => issue})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_list_comments(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    with {:ok, issue_id} <- required_string_argument(arguments, "issueId"),
         {:ok, comments} <- tracker_module.list_comments(issue_id) do
      success_response(%{"comments" => comments})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_create_comment(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    with {:ok, issue_id} <- required_string_argument(arguments, "issueId"),
         {:ok, body} <- required_string_argument(arguments, "body"),
         :ok <- tracker_module.create_comment(issue_id, body) do
      success_response(%{"ok" => true})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_update_comment(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    with {:ok, comment_id} <- required_string_argument(arguments, "commentId"),
         {:ok, body} <- required_string_argument(arguments, "body"),
         issue_id <- optional_string_argument(arguments, "issueId"),
         :ok <- tracker_module.update_comment(comment_id, body, issue_id) do
      success_response(%{"ok" => true})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_transition_issue(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    with {:ok, issue_id} <- required_string_argument(arguments, "issueId"),
         {:ok, state_name} <- normalize_transition_target(arguments),
         :ok <- tracker_module.update_issue_state(issue_id, state_name) do
      success_response(%{"ok" => true, "state" => state_name})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_attach_pr(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    with {:ok, issue_id} <- required_string_argument(arguments, "issueId"),
         {:ok, url} <- required_string_argument(arguments, "url"),
         title <- optional_string_argument(arguments, "title"),
         :ok <- tracker_module.attach_pr(issue_id, url, title) do
      success_response(%{"ok" => true})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_attach_url(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    with {:ok, issue_id} <- required_string_argument(arguments, "issueId"),
         {:ok, url} <- required_string_argument(arguments, "url"),
         title <- optional_string_argument(arguments, "title"),
         :ok <- tracker_module.attach_url(issue_id, url, title) do
      success_response(%{"ok" => true})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tracker_upload_attachment(arguments, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)
    file_reader = Keyword.get(opts, :file_reader, &File.read/1)

    with {:ok, issue_id} <- required_string_argument(arguments, "issueId"),
         {:ok, path} <- required_string_argument(arguments, "path"),
         filename <- optional_string_argument(arguments, "filename") || Path.basename(path),
         content_type <- optional_string_argument(arguments, "contentType") || infer_content_type(filename),
         {:ok, body} <- file_reader.(path),
         {:ok, attachment} <- tracker_module.upload_attachment(issue_id, filename, content_type, body) do
      success_response(%{"attachment" => attachment})
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    with {:ok, query} <- normalize_query(arguments),
         {:ok, variables} <- normalize_variables(arguments) do
      {:ok, query, variables}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_jira_rest_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_http_method(arguments),
         {:ok, path} <- required_string_argument(arguments, "path"),
         {:ok, query} <- normalize_optional_map(arguments, "query"),
         {:ok, body} <- normalize_optional_map(arguments, "body") do
      opts =
        []
        |> maybe_put_jira_query(query)
        |> maybe_put_jira_json(body)

      {:ok, method, String.trim(path), opts}
    end
  end

  defp normalize_jira_rest_arguments(_arguments), do: {:error, :invalid_jira_rest_arguments}

  defp normalize_http_method(arguments) do
    case optional_string_argument(arguments, "method") do
      method when is_binary(method) ->
        case method |> String.trim() |> String.downcase() do
          "get" -> {:ok, :get}
          "post" -> {:ok, :post}
          "put" -> {:ok, :put}
          _ -> {:error, :invalid_jira_rest_method}
        end

      _ ->
        {:error, :invalid_jira_rest_method}
    end
  end

  defp validate_jira_rest_path(method, path, request_opts) when is_atom(method) and is_binary(path) do
    case classify_jira_rest_path(method, path) do
      :myself -> :ok
      :search -> validate_jira_search_scope(request_opts)
      :issue_scoped -> validate_jira_issue_scope(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_jira_rest_path(method, path) do
    cond do
      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        {:error, :jira_rest_absolute_path_disallowed}

      String.contains?(path, "..") ->
        {:error, :jira_rest_path_disallowed}

      method == :get and path == "/rest/api/3/myself" ->
        :myself

      method in [:get, :post] and path in ["/rest/api/3/search", "/rest/api/3/search/jql"] ->
        :search

      true ->
        classify_issue_scoped_path(method, path)
    end
  end

  defp classify_issue_scoped_path(method, path) do
    if allowed_issue_path?(method, path) do
      :issue_scoped
    else
      {:error, :jira_rest_path_disallowed}
    end
  end

  defp allowed_issue_path?(method, path) do
    cond do
      Regex.match?(~r{^/rest/api/3/issue/[^/]+$}, path) ->
        method == :get

      Regex.match?(~r{^/rest/api/3/issue/[^/]+/comment$}, path) ->
        method in [:get, :post]

      Regex.match?(~r{^/rest/api/3/issue/[^/]+/comment/[^/]+$}, path) ->
        method == :put

      Regex.match?(~r{^/rest/api/3/issue/[^/]+/transitions$}, path) ->
        method in [:get, :post]

      Regex.match?(~r{^/rest/api/3/issue/[^/]+/remotelink$}, path) ->
        method == :post

      Regex.match?(~r{^/rest/api/3/issue/[^/]+/attachments$}, path) ->
        method == :post

      true ->
        false
    end
  end

  defp validate_jira_issue_scope(path) do
    case issue_key_or_id_from_path(path) do
      nil -> {:error, :jira_rest_path_disallowed}
      issue_key_or_id -> validate_jira_issue_key_scope(issue_key_or_id)
    end
  end

  defp issue_key_or_id_from_path(path) do
    path
    |> String.split("/")
    |> Enum.at(5)
  end

  defp validate_jira_issue_key_scope(issue_key_or_id) do
    case Regex.run(~r/^([A-Za-z][A-Za-z0-9]+)-\d+$/, issue_key_or_id) do
      [_, project_key] -> validate_jira_project_scope(project_key)
      _ -> :ok
    end
  end

  defp validate_jira_project_scope(project_key) do
    configured_project_key =
      Config.jira_project_key()
      |> Kernel.||("")
      |> String.upcase()

    if String.upcase(project_key) == configured_project_key do
      :ok
    else
      {:error, :jira_rest_out_of_scope_issue}
    end
  end

  defp validate_jira_search_scope(request_opts) do
    case Keyword.get(request_opts, :json, %{}) do
      %{"jql" => jql} when is_binary(jql) ->
        project_key = String.upcase(Config.jira_project_key() || "")

        if String.contains?(String.upcase(jql), project_key) do
          :ok
        else
          {:error, :jira_rest_out_of_scope_search}
        end

      _ ->
        :ok
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_optional_map(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) || %{} do
      value when value in [%{}, nil] -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_jira_rest_body}
    end
  end

  defp required_string_argument(arguments, key) when is_map(arguments) do
    case optional_string_argument(arguments, key) do
      nil -> {:error, {:missing_argument, key}}
      value -> {:ok, value}
    end
  end

  defp required_string_argument(_arguments, key), do: {:error, {:missing_argument, key}}

  defp optional_string_argument(arguments, key) when is_map(arguments) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp optional_string_argument(_arguments, _key), do: nil

  defp normalize_transition_target(arguments) do
    case optional_string_argument(arguments, "state") do
      state when is_binary(state) ->
        {:ok, state}

      _ ->
        normalize_semantic_transition_target(arguments)
    end
  end

  defp normalize_semantic_transition_target(arguments) do
    case optional_string_argument(arguments, "semanticState") do
      semantic_state when is_binary(semantic_state) ->
        resolve_semantic_transition_target(semantic_state)

      _ ->
        {:error, :missing_transition_target}
    end
  end

  defp resolve_semantic_transition_target(semantic_state) do
    case Config.target_tracker_state_for_semantic_state(semantic_state) do
      state when is_binary(state) -> {:ok, state}
      _ -> {:error, :unknown_semantic_state}
    end
  end

  defp maybe_put_jira_query(opts, %{} = query) when map_size(query) > 0 do
    Keyword.put(opts, :query, Map.to_list(query))
  end

  defp maybe_put_jira_query(opts, _query), do: opts

  defp maybe_put_jira_json(opts, %{} = body) when map_size(body) > 0 do
    Keyword.put(opts, :json, body)
  end

  defp maybe_put_jira_json(opts, _body), do: opts

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    response_payload(success, response)
  end

  defp success_response(payload), do: response_payload(true, payload)
  defp failure_response(payload), do: response_payload(false, payload)

  defp response_payload(success, payload) do
    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) do
    payload
    |> json_safe_value()
    |> case do
      value when is_map(value) or is_list(value) -> Jason.encode!(value, pretty: true)
      value -> inspect(value)
    end
  end

  defp json_safe_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe_value(%Time{} = value), do: Time.to_iso8601(value)
  defp json_safe_value(%_{} = value), do: value |> Map.from_struct() |> json_safe_value()
  defp json_safe_value(value) when is_map(value), do: Map.new(value, fn {key, item} -> {to_string(key), json_safe_value(item)} end)
  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)
  defp json_safe_value(value), do: value

  @content_types %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".json" => "application/json",
    ".md" => "text/markdown",
    ".mov" => "video/quicktime",
    ".mp4" => "video/mp4",
    ".png" => "image/png",
    ".txt" => "text/plain"
  }

  defp infer_content_type(filename) do
    filename
    |> Path.extname()
    |> String.downcase()
    |> then(&Map.get(@content_types, &1, "application/octet-stream"))
  end

  defp tool_error_payload(:missing_query) do
    %{"error" => %{"message" => "`linear_graphql` requires a non-empty `query` string."}}
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{"error" => %{"message" => "`linear_graphql.variables` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{"error" => %{"message" => "Linear GraphQL request failed with HTTP #{status}.", "status" => status}}
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:invalid_jira_rest_arguments) do
    %{"error" => %{"message" => "`jira_rest` expects an object with `method`, `path`, and optional `query` / `body`."}}
  end

  defp tool_error_payload(:invalid_jira_rest_method) do
    %{"error" => %{"message" => "`jira_rest.method` must be one of GET, POST, or PUT."}}
  end

  defp tool_error_payload(:invalid_jira_rest_body) do
    %{"error" => %{"message" => "`jira_rest.query` and `jira_rest.body` must be JSON objects when provided."}}
  end

  defp tool_error_payload(:jira_rest_absolute_path_disallowed) do
    %{"error" => %{"message" => "`jira_rest.path` must be a relative Jira API path, not an absolute URL."}}
  end

  defp tool_error_payload(:jira_rest_path_disallowed) do
    %{"error" => %{"message" => "`jira_rest.path` is not allowlisted by Symphony."}}
  end

  defp tool_error_payload(:jira_rest_out_of_scope_issue) do
    %{"error" => %{"message" => "`jira_rest` rejected a path outside the configured Jira project scope."}}
  end

  defp tool_error_payload(:jira_rest_out_of_scope_search) do
    %{"error" => %{"message" => "`jira_rest` rejected a search that does not target the configured Jira project."}}
  end

  defp tool_error_payload(:missing_jira_site_url) do
    %{"error" => %{"message" => "Symphony is missing Jira site config. Set `tracker.site_url` or export `JIRA_SITE_URL`."}}
  end

  defp tool_error_payload(:missing_jira_auth_email) do
    %{"error" => %{"message" => "Symphony is missing Jira auth email. Set `tracker.auth.email` or export `JIRA_EMAIL`."}}
  end

  defp tool_error_payload(:missing_jira_api_token) do
    %{"error" => %{"message" => "Symphony is missing Jira auth token. Set `tracker.auth.api_token` or export `JIRA_API_TOKEN`."}}
  end

  defp tool_error_payload(:missing_jira_project_key) do
    %{"error" => %{"message" => "Symphony is missing Jira project scope. Set `tracker.project_key` or export `JIRA_PROJECT_KEY`."}}
  end

  defp tool_error_payload(:jira_issue_id_required_for_comment_update) do
    %{"error" => %{"message" => "Jira comment updates require `issueId` so Symphony can keep the request scoped to the configured project."}}
  end

  defp tool_error_payload({:jira_rate_limited, retry_after, metadata}) do
    %{
      "error" => %{
        "message" => "Jira REST request was rate limited.",
        "retryAfterSeconds" => retry_after,
        "rateLimits" => metadata
      }
    }
  end

  defp tool_error_payload({:jira_api_status, status}) do
    %{"error" => %{"message" => "Jira REST request failed with HTTP #{status}.", "status" => status}}
  end

  defp tool_error_payload({:jira_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Jira REST request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:missing_argument, key}) do
    %{"error" => %{"message" => "Missing required argument: #{key}."}}
  end

  defp tool_error_payload(:missing_transition_target) do
    %{"error" => %{"message" => "Provide either `state` or `semanticState` when calling `tracker_transition_issue`."}}
  end

  defp tool_error_payload(:unknown_semantic_state) do
    %{"error" => %{"message" => "The requested `semanticState` is not configured in `tracker.state_map`."}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "Dynamic tool execution failed.", "reason" => inspect(reason)}}
  end

  defp linear_tool_error_payload(reason) do
    case tool_error_payload(reason) do
      %{"error" => %{"message" => "Dynamic tool execution failed.", "reason" => reason_text}} ->
        %{"error" => %{"message" => "Linear GraphQL tool execution failed.", "reason" => reason_text}}

      payload ->
        payload
    end
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
