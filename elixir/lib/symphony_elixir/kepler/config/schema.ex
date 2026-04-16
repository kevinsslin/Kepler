defmodule SymphonyElixir.Kepler.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @fixed_linear_webhook_path "/webhooks/linear"

  @primary_key false

  @type t :: %__MODULE__{}
  @type linear_auth_mode :: :api_key | :client_credentials | :unconfigured

  @spec fixed_linear_webhook_path() :: String.t()
  def fixed_linear_webhook_path, do: @fixed_linear_webhook_path

  @spec default_fallback_workflow_path() :: String.t()
  def default_fallback_workflow_path do
    Application.app_dir(:symphony_elixir, "priv/templates/WORKFLOW.kepler.template.md")
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:host, :string, default: "0.0.0.0")
      field(:port, :integer, default: 4040)
      field(:api_token, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:host, :port, :api_token], empty_values: [])
      |> validate_required([:host, :port])
      |> validate_number(:port, greater_than: 0)
    end
  end

  defmodule Linear do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset
    alias SymphonyElixir.Kepler.Config.Schema.Repository

    @primary_key false

    @type t :: %__MODULE__{}

    embedded_schema do
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:client_id, :string)
      field(:client_secret, :string)
      field(:oauth_token_url, :string, default: "https://api.linear.app/oauth/token")
      field(:oauth_scopes, {:array, :string}, default: ["read", "write", "app:assignable", "app:mentionable"])
      field(:webhook_secret, :string)
      field(:workspace_id, :string)
      field(:agent_name, :string, default: "Kepler")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :endpoint,
          :api_key,
          :client_id,
          :client_secret,
          :oauth_token_url,
          :oauth_scopes,
          :webhook_secret,
          :workspace_id,
          :agent_name
        ],
        empty_values: []
      )
      |> update_change(:oauth_scopes, &Repository.normalize_string_list/1)
      |> validate_required([:endpoint, :oauth_token_url, :oauth_scopes, :webhook_secret])
      |> validate_length(:oauth_scopes, min: 1)
    end
  end

  defmodule GitHub do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:api_url, :string, default: "https://api.github.com")
      field(:app_id, :string)
      field(:private_key, :string)
      field(:private_key_path, :string)
      field(:bot_name, :string, default: "Kepler Bot")
      field(:bot_email, :string, default: "kepler-bot@users.noreply.github.com")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:api_url, :app_id, :private_key, :private_key_path, :bot_name, :bot_email], empty_values: [])
      |> validate_required([:api_url, :bot_name, :bot_email])
    end
  end

  @spec linear_auth_mode(Linear.t()) :: linear_auth_mode()
  def linear_auth_mode(%Linear{} = linear) do
    cond do
      present?(linear.client_id) and present?(linear.client_secret) -> :client_credentials
      present?(linear.api_key) -> :api_key
      true -> :unconfigured
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "kepler_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
      |> validate_required([:root])
    end
  end

  defmodule State do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "kepler_state"))
      field(:file_name, :string, default: "runs.json")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :file_name], empty_values: [])
      |> validate_required([:root, :file_name])
    end
  end

  defmodule Limits do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:max_concurrent_runs, :integer, default: 2)
      field(:dispatch_interval_ms, :integer, default: 1_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:max_concurrent_runs, :dispatch_interval_ms], empty_values: [])
      |> validate_required([:max_concurrent_runs, :dispatch_interval_ms])
      |> validate_number(:max_concurrent_runs, greater_than: 0)
      |> validate_number(:dispatch_interval_ms, greater_than: 0)
    end
  end

  defmodule Routing do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:fallback_workflow_path, :string)
      field(:ambiguous_choice_limit, :integer, default: 3)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:fallback_workflow_path, :ambiguous_choice_limit], empty_values: [])
      |> validate_required([:fallback_workflow_path, :ambiguous_choice_limit])
      |> validate_number(:ambiguous_choice_limit, greater_than: 1)
    end
  end

  defmodule Repository do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    @type t :: %__MODULE__{}

    embedded_schema do
      field(:id, :string)
      field(:full_name, :string)
      field(:clone_url, :string)
      field(:default_branch, :string, default: "main")
      field(:workflow_path, :string, default: "WORKFLOW.md")
      field(:provider, :string, default: "codex")
      field(:github_installation_id, :integer)
      field(:labels, {:array, :string}, default: [])
      field(:team_keys, {:array, :string}, default: [])
      field(:project_ids, {:array, :string}, default: [])
      field(:project_slugs, {:array, :string}, default: [])
      field(:reference_repository_ids, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :id,
          :full_name,
          :clone_url,
          :default_branch,
          :workflow_path,
          :provider,
          :github_installation_id,
          :labels,
          :team_keys,
          :project_ids,
          :project_slugs,
          :reference_repository_ids
        ],
        empty_values: []
      )
      |> validate_required([:id, :full_name, :clone_url, :default_branch, :workflow_path, :provider])
      |> update_change(:labels, &normalize_string_list/1)
      |> update_change(:team_keys, &normalize_string_list/1)
      |> update_change(:project_ids, &normalize_string_list/1)
      |> update_change(:project_slugs, &normalize_string_list/1)
      |> update_change(:reference_repository_ids, &normalize_string_list/1)
      |> validate_inclusion(:provider, ["codex"])
    end

    @spec normalize_string_list(nil | [term()]) :: [String.t()]
    def normalize_string_list(nil), do: []

    def normalize_string_list(values) when is_list(values) do
      values
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  embedded_schema do
    field(:service_name, :string, default: "Kepler")
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:linear, Linear, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github, GitHub, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:state, State, on_replace: :update, defaults_to_struct: true)
    embeds_one(:limits, Limits, on_replace: :update, defaults_to_struct: true)
    embeds_one(:routing, Routing, on_replace: :update, defaults_to_struct: true)
    embeds_many(:repositories, Repository, on_replace: :delete)
  end

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_kepler_config, String.t()}}
  def parse(config) when is_map(config) do
    normalized_config =
      config
      |> normalize_keys()
      |> drop_nil_values()

    with :ok <- validate_fixed_webhook_path(normalized_config),
         {:ok, settings} <- validate_changeset(normalized_config),
         {:ok, finalized_settings} <- finalize_settings(settings) do
      validate_runtime_settings(finalized_settings)
    end
  end

  @spec state_file_path(t()) :: Path.t()
  def state_file_path(settings) do
    Path.join(settings.state.root, settings.state.file_name)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:service_name])
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:linear, with: &Linear.changeset/2)
    |> cast_embed(:github, with: &GitHub.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:state, with: &State.changeset/2)
    |> cast_embed(:limits, with: &Limits.changeset/2)
    |> cast_embed(:routing, with: &Routing.changeset/2)
    |> cast_embed(:repositories, with: &Repository.changeset/2)
  end

  defp validate_changeset(attrs) do
    attrs
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, settings}

      {:error, changeset} ->
        {:error, {:invalid_kepler_config, format_errors(changeset)}}
    end
  end

  defp finalize_settings(settings) do
    with {:ok, github_private_key} <-
           resolve_private_key(settings.github.private_key, settings.github.private_key_path) do
      github = %{
        settings.github
        | app_id: resolve_secret_setting(settings.github.app_id, nil),
          private_key: github_private_key
      }

      linear = %{
        settings.linear
        | api_key: resolve_secret_setting(settings.linear.api_key, System.get_env("LINEAR_API_KEY")),
          client_id: resolve_secret_setting(settings.linear.client_id, System.get_env("LINEAR_CLIENT_ID")),
          client_secret:
            resolve_secret_setting(
              settings.linear.client_secret,
              System.get_env("LINEAR_CLIENT_SECRET")
            ),
          webhook_secret:
            resolve_secret_setting(
              settings.linear.webhook_secret,
              System.get_env("LINEAR_WEBHOOK_SECRET")
            )
      }

      server = %{
        settings.server
        | api_token: resolve_secret_setting(settings.server.api_token, System.get_env("KEPLER_API_TOKEN"))
      }

      workspace = %{
        settings.workspace
        | root:
            resolve_path_value(
              settings.workspace.root,
              Path.join(System.tmp_dir!(), "kepler_workspaces")
            )
      }

      state = %{
        settings.state
        | root: resolve_path_value(settings.state.root, Path.join(System.tmp_dir!(), "kepler_state"))
      }

      routing = %{
        settings.routing
        | fallback_workflow_path:
            resolve_path_value(
              settings.routing.fallback_workflow_path,
              default_fallback_workflow_path()
            )
      }

      {:ok,
       %{
         settings
         | server: server,
           github: github,
           linear: linear,
           workspace: workspace,
           state: state,
           routing: routing
       }}
    end
  end

  defp validate_runtime_settings(settings) do
    []
    |> maybe_add_missing_secret("linear.webhook_secret", settings.linear.webhook_secret)
    |> validate_linear_auth(settings.linear)
    |> validate_github_auth(settings.github)
    |> validate_reference_repositories(settings.repositories)
    |> case do
      [] ->
        {:ok, settings}

      errors ->
        {:error, {:invalid_kepler_config, Enum.join(errors, ", ")}}
    end
  end

  defp validate_fixed_webhook_path(config) do
    case get_in(config, ["linear", "webhook_path"]) do
      nil ->
        :ok

      @fixed_linear_webhook_path ->
        :ok

      other ->
        {:error, {:invalid_kepler_config, "linear.webhook_path is fixed at #{@fixed_linear_webhook_path} in Kepler v1, got #{inspect(other)}"}}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_private_key(private_key, private_key_path) do
    inline_value = resolve_secret_setting(private_key, nil)

    cond do
      is_binary(inline_value) and inline_value != "" ->
        {:ok, inline_value}

      is_binary(private_key_path) and String.trim(private_key_path) != "" ->
        private_key_path
        |> resolve_path_value(nil)
        |> read_private_key_file()

      true ->
        {:ok, normalize_secret_value(System.get_env("GITHUB_APP_PRIVATE_KEY"))}
    end
  end

  defp read_private_key_file(nil), do: {:ok, nil}

  defp read_private_key_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, {:invalid_kepler_config, "github.private_key_path could not be read from #{path}: #{inspect(reason)}"}}
    end
  end

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        Path.expand(path)
    end
  end

  defp resolve_path_value(nil, default), do: default

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
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

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_secret_value(_value), do: nil

  defp maybe_add_missing_secret(errors, _field, value) when is_binary(value) and value != "",
    do: errors

  defp maybe_add_missing_secret(errors, field, _value) do
    errors ++ ["#{field} must resolve to a non-empty value at boot time"]
  end

  defp validate_linear_auth(errors, %Linear{} = linear) do
    cond do
      present?(linear.client_id) or present?(linear.client_secret) ->
        errors
        |> maybe_add_missing_secret("linear.client_id", linear.client_id)
        |> maybe_add_missing_secret("linear.client_secret", linear.client_secret)

      present?(linear.api_key) ->
        maybe_add_missing_secret(errors, "linear.api_key", linear.api_key)

      true ->
        errors ++
          [
            "either linear.client_id + linear.client_secret or linear.api_key must resolve to non-empty values at boot time"
          ]
    end
  end

  defp validate_github_auth(errors, github) do
    github_token = normalize_secret_value(System.get_env("GITHUB_TOKEN"))

    cond do
      is_binary(github_token) and github_token != "" ->
        errors

      present?(github.app_id) and present?(github.private_key) ->
        case validate_private_key(github.private_key) do
          :ok ->
            errors

          {:error, _message} ->
            errors ++ ["github.private_key must be a valid PEM-encoded private key"]
        end

      true ->
        errors ++
          [
            "github auth is required: set GITHUB_TOKEN or configure github.app_id plus github.private_key/private_key_path"
          ]
    end
  end

  defp validate_private_key(private_key) when is_binary(private_key) do
    case :public_key.pem_decode(private_key) do
      [entry | _rest] ->
        try do
          _ = :public_key.pem_entry_decode(entry)
          :ok
        rescue
          _error -> {:error, "must be a valid PEM-encoded private key"}
        catch
          _kind, _reason -> {:error, "must be a valid PEM-encoded private key"}
        end

      _ ->
        {:error, "must be a valid PEM-encoded private key"}
    end
  end

  defp validate_private_key(_private_key),
    do: {:error, "must be a valid PEM-encoded private key"}

  defp validate_reference_repositories(errors, repositories) when is_list(repositories) do
    known_ids = MapSet.new(Enum.map(repositories, & &1.id))

    reference_errors =
      repositories
      |> Enum.flat_map(fn repository ->
        Enum.flat_map(repository.reference_repository_ids || [], fn reference_id ->
          cond do
            reference_id == repository.id ->
              ["repositories.#{repository.id}.reference_repository_ids cannot include itself"]

            MapSet.member?(known_ids, reference_id) ->
              []

            true ->
              ["repositories.#{repository.id}.reference_repository_ids includes unknown repository #{inspect(reference_id)}"]
          end
        end)
      end)

    errors ++ reference_errors
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
