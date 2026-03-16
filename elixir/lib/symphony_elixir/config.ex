defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias SymphonyElixir.{Tracker.SemanticState, Workflow}

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_jira_auth_type "api_token"
  @default_jira_blocks_inward ["is blocked by"]
  @default_prompt_template """
  You are working on a tracker issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_poll_interval_ms 30_000
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_codex_command "codex app-server"
  @default_codex_turn_timeout_ms 3_600_000
  @default_codex_read_timeout_ms 5_000
  @default_codex_stall_timeout_ms 300_000
  @default_codex_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_codex_thread_sandbox "workspace-write"
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_server_host "127.0.0.1"
  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 site_url: [type: {:or, [:string, nil]}, default: nil],
                                 project_key: [type: {:or, [:string, nil]}, default: nil],
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ],
                                 state_map: [
                                   type: {:map, :string, {:list, :string}},
                                   default: %{}
                                 ],
                                 auth: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     type: [
                                       type: {:or, [:string, nil]},
                                       default: @default_jira_auth_type
                                     ],
                                     email: [type: {:or, [:string, nil]}, default: nil],
                                     api_token: [type: {:or, [:string, nil]}, default: nil]
                                   ]
                                 ],
                                 link_types: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     blocks_inward: [
                                       type: {:list, :string},
                                       default: @default_jira_blocks_inward
                                     ]
                                   ]
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ]
                               ]
                             ],
                             codex: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_codex_command],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_turn_timeout_ms
                                 ],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_read_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_stall_timeout_ms
                                 ]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec tracker_assignee() :: String.t() | nil
  def tracker_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :assignee])
    |> resolve_env_value(System.get_env(tracker_assignee_env_name()))
    |> normalize_secret_value()
  end

  @spec tracker_active_states() :: [String.t()]
  def tracker_active_states do
    case tracker_state_map() do
      %{} = state_map when map_size(state_map) > 0 ->
        SemanticState.dispatchable()
        |> Enum.flat_map(&Map.get(state_map, &1, []))
        |> Enum.uniq()

      _ ->
        get_in(validated_workflow_options(), [:tracker, :active_states])
    end
  end

  @spec tracker_terminal_states() :: [String.t()]
  def tracker_terminal_states do
    case tracker_state_map() do
      %{} = state_map when map_size(state_map) > 0 ->
        Map.get(state_map, "terminal", get_in(validated_workflow_options(), [:tracker, :terminal_states]))

      _ ->
        get_in(validated_workflow_options(), [:tracker, :terminal_states])
    end
  end

  @spec tracker_state_map() :: %{optional(String.t()) => [String.t()]}
  def tracker_state_map do
    validated_workflow_options()
    |> get_in([:tracker, :state_map])
    |> normalize_state_map()
    |> fallback_state_map()
  end

  @spec semantic_state_for_tracker_state(term()) :: String.t() | nil
  def semantic_state_for_tracker_state(state_name) do
    normalized_state_name = normalize_issue_state(state_name)

    Enum.find_value(tracker_state_map(), fn {semantic_state, state_names} ->
      if Enum.any?(state_names, &(normalize_issue_state(&1) == normalized_state_name)) do
        semantic_state
      end
    end)
  end

  @spec target_tracker_state_for_semantic_state(term()) :: String.t() | nil
  def target_tracker_state_for_semantic_state(semantic_state) do
    semantic_state
    |> SemanticState.normalize()
    |> then(fn
      nil -> nil
      normalized -> tracker_state_map() |> Map.get(normalized, []) |> List.first()
    end)
  end

  @spec tracker_project_reference() :: String.t() | nil
  def tracker_project_reference do
    case tracker_kind() do
      "jira" -> jira_project_key()
      _ -> linear_project_slug()
    end
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    get_in(validated_workflow_options(), [:tracker, :endpoint])
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :api_key])
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    get_in(validated_workflow_options(), [:tracker, :project_slug])
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    tracker_assignee()
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    tracker_active_states()
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    tracker_terminal_states()
  end

  @spec jira_site_url() :: String.t() | nil
  def jira_site_url do
    validated_workflow_options()
    |> get_in([:tracker, :site_url])
    |> resolve_env_value(System.get_env("JIRA_SITE_URL"))
    |> normalize_secret_value()
  end

  @spec jira_project_key() :: String.t() | nil
  def jira_project_key do
    validated_workflow_options()
    |> get_in([:tracker, :project_key])
    |> resolve_env_value(System.get_env("JIRA_PROJECT_KEY"))
    |> normalize_secret_value()
  end

  @spec jira_auth_type() :: String.t()
  def jira_auth_type do
    validated_workflow_options()
    |> get_in([:tracker, :auth, :type])
    |> scalar_string_or_default(@default_jira_auth_type)
    |> String.downcase()
  end

  @spec jira_auth_email() :: String.t() | nil
  def jira_auth_email do
    validated_workflow_options()
    |> get_in([:tracker, :auth, :email])
    |> resolve_env_value(System.get_env("JIRA_EMAIL"))
    |> normalize_secret_value()
  end

  @spec jira_api_token() :: String.t() | nil
  def jira_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :auth, :api_token])
    |> resolve_env_value(System.get_env("JIRA_API_TOKEN"))
    |> normalize_secret_value()
  end

  @spec jira_blocks_inward_link_names() :: [String.t()]
  def jira_blocks_inward_link_names do
    validated_workflow_options()
    |> get_in([:tracker, :link_types, :blocks_inward])
    |> normalize_string_list(@default_jira_blocks_inward)
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :interval_ms])
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec codex_command() :: String.t()
  def codex_command do
    get_in(validated_workflow_options(), [:codex, :command])
  end

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :turn_timeout_ms])
  end

  @spec codex_approval_policy() :: String.t() | map()
  def codex_approval_policy do
    case resolve_codex_approval_policy() do
      {:ok, approval_policy} -> approval_policy
      {:error, _reason} -> @default_codex_approval_policy
    end
  end

  @spec codex_thread_sandbox() :: String.t()
  def codex_thread_sandbox do
    case resolve_codex_thread_sandbox() do
      {:ok, thread_sandbox} -> thread_sandbox
      {:error, _reason} -> @default_codex_thread_sandbox
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case resolve_codex_turn_sandbox_policy(workspace) do
      {:ok, turn_sandbox_policy} -> turn_sandbox_policy
      {:error, _reason} -> default_codex_turn_sandbox_policy(workspace)
    end
  end

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :read_timeout_ms])
  end

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:codex, :stall_timeout_ms])
    |> max(0)
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_kind(),
         :ok <- require_linear_token(),
         :ok <- require_linear_project(),
         :ok <- require_jira_site_url(),
         :ok <- require_jira_project_key(),
         :ok <- require_jira_auth(),
         :ok <- require_valid_codex_runtime_settings() do
      require_codex_command()
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, approval_policy} <- resolve_codex_approval_policy(),
         {:ok, thread_sandbox} <- resolve_codex_thread_sandbox(),
         {:ok, turn_sandbox_policy} <- resolve_codex_turn_sandbox_policy(workspace) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "linear" -> :ok
      "jira" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_api_token()) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_project_slug()) do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_jira_site_url do
    case tracker_kind() do
      "jira" ->
        if is_binary(jira_site_url()) do
          :ok
        else
          {:error, :missing_jira_site_url}
        end

      _ ->
        :ok
    end
  end

  defp require_jira_project_key do
    case tracker_kind() do
      "jira" ->
        if is_binary(jira_project_key()) do
          :ok
        else
          {:error, :missing_jira_project_key}
        end

      _ ->
        :ok
    end
  end

  defp require_jira_auth do
    case tracker_kind() do
      "jira" ->
        require_jira_auth_type(jira_auth_type())

      _ ->
        :ok
    end
  end

  defp require_jira_auth_type("api_token"), do: require_jira_api_token_auth()
  defp require_jira_auth_type(other), do: {:error, {:unsupported_jira_auth_type, other}}

  defp require_jira_api_token_auth do
    cond do
      not is_binary(jira_auth_email()) -> {:error, :missing_jira_auth_email}
      not is_binary(jira_api_token()) -> {:error, :missing_jira_api_token}
      true -> :ok
    end
  end

  defp require_codex_command do
    if byte_size(String.trim(codex_command())) > 0 do
      :ok
    else
      {:error, :missing_codex_command}
    end
  end

  defp require_valid_codex_runtime_settings do
    case codex_runtime_settings() do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validated_workflow_options do
    workflow_config()
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      codex: extract_codex_options(section_map(config, "codex")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:project_slug, scalar_string_value(Map.get(section, "project_slug")))
    |> put_if_present(:site_url, scalar_string_value(Map.get(section, "site_url")))
    |> put_if_present(:project_key, scalar_string_value(Map.get(section, "project_key")))
    |> put_if_present(:assignee, binary_value(Map.get(section, "assignee"), allow_empty: true))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
    |> put_if_present(:state_map, state_map_value(Map.get(section, "state_map")))
    |> put_if_present(:auth, tracker_auth_value(Map.get(section, "auth")))
    |> put_if_present(:link_types, tracker_link_types_value(Map.get(section, "link_types")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
  end

  defp extract_codex_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:read_timeout_ms, integer_value(Map.get(section, "read_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp command_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp state_map_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {semantic_state, states}, acc ->
      case normalized_state_map_entry(semantic_state, states) do
        nil -> acc
        {normalized_semantic_state, normalized_states} -> Map.put(acc, normalized_semantic_state, normalized_states)
      end
    end)
  end

  defp state_map_value(_value), do: :omit

  defp normalized_state_map_entry(semantic_state, states) do
    with normalized_semantic_state when not is_nil(normalized_semantic_state) <-
           SemanticState.normalize(semantic_state),
         normalized_states when normalized_states != :omit <- csv_value(states) do
      {normalized_semantic_state, normalized_states}
    else
      _ -> nil
    end
  end

  defp tracker_auth_value(value) when is_map(value) do
    %{}
    |> put_if_present(:type, scalar_string_value(Map.get(value, "type")))
    |> put_if_present(:email, binary_value(Map.get(value, "email"), allow_empty: true))
    |> put_if_present(:api_token, binary_value(Map.get(value, "api_token"), allow_empty: true))
  end

  defp tracker_auth_value(_value), do: :omit

  defp tracker_link_types_value(value) when is_map(value) do
    %{}
    |> put_if_present(:blocks_inward, csv_value(Map.get(value, "blocks_inward")))
  end

  defp tracker_link_types_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp fetch_value(paths, default) do
    config = workflow_config()

    case resolve_config_value(config, paths) do
      :missing -> default
      value -> value
    end
  end

  defp resolve_codex_approval_policy do
    case fetch_value([["codex", "approval_policy"]], :missing) do
      :missing ->
        {:ok, @default_codex_approval_policy}

      nil ->
        {:ok, @default_codex_approval_policy}

      value when is_binary(value) ->
        approval_policy = String.trim(value)

        if approval_policy == "" do
          {:error, {:invalid_codex_approval_policy, value}}
        else
          {:ok, approval_policy}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_approval_policy, value}}
    end
  end

  defp resolve_codex_thread_sandbox do
    case fetch_value([["codex", "thread_sandbox"]], :missing) do
      :missing ->
        {:ok, @default_codex_thread_sandbox}

      nil ->
        {:ok, @default_codex_thread_sandbox}

      value when is_binary(value) ->
        thread_sandbox = String.trim(value)

        if thread_sandbox == "" do
          {:error, {:invalid_codex_thread_sandbox, value}}
        else
          {:ok, thread_sandbox}
        end

      value ->
        {:error, {:invalid_codex_thread_sandbox, value}}
    end
  end

  defp resolve_codex_turn_sandbox_policy(workspace) do
    case fetch_value([["codex", "turn_sandbox_policy"]], :missing) do
      :missing ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      nil ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, value}}}
    end
  end

  defp default_codex_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(workspace_root())
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp normalize_state_map(%{} = state_map) do
    state_map
    |> Enum.reduce(%{}, fn {semantic_state, state_names}, acc ->
      case SemanticState.normalize(semantic_state) do
        nil -> acc
        normalized -> Map.put(acc, normalized, normalize_string_list(state_names, []))
      end
    end)
    |> Enum.reject(fn {_semantic_state, state_names} -> state_names == [] end)
    |> Map.new()
  end

  defp normalize_state_map(_state_map), do: %{}

  defp fallback_state_map(state_map) when map_size(state_map) > 0, do: state_map

  defp fallback_state_map(_state_map) do
    %{
      "active" => get_in(validated_workflow_options(), [:tracker, :active_states]),
      "terminal" => get_in(validated_workflow_options(), [:tracker, :terminal_states])
    }
  end

  defp normalize_string_list(values, default)

  defp normalize_string_list(values, default) when is_list(values) do
    values
    |> Enum.map(&scalar_string_value/1)
    |> Enum.reject(&(&1 in [:omit, ""]))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default
      normalized_values -> normalized_values
    end
  end

  defp normalize_string_list(_values, default), do: default

  defp scalar_string_or_default(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp scalar_string_or_default(_value, default), do: default

  defp tracker_assignee_env_name do
    case tracker_kind() do
      "jira" -> "JIRA_ASSIGNEE"
      _ -> "LINEAR_ASSIGNEE"
    end
  end

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
