defmodule SymphonyElixir.Kepler.Config do
  @moduledoc """
  Loads Kepler runtime configuration from YAML.
  """

  alias SymphonyElixir.Kepler.Config.Schema

  @default_config_file_name "kepler.yml"
  @settings_cache_key :kepler_settings
  @settings_source_cache_key :kepler_settings_source_path

  @spec config_file_path() :: Path.t()
  def config_file_path do
    Application.get_env(:symphony_elixir, :kepler_config_file_path) ||
      Path.join(File.cwd!(), @default_config_file_name)
  end

  @spec set_config_file_path(Path.t()) :: :ok
  def set_config_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :kepler_config_file_path, path)
    clear_cached_settings()
    :ok
  end

  @spec clear_config_file_path() :: :ok
  def clear_config_file_path do
    Application.delete_env(:symphony_elixir, :kepler_config_file_path)
    clear_cached_settings()
    :ok
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    path = config_file_path()

    case cached_settings(path) do
      {:ok, settings} ->
        {:ok, settings}

      :error ->
        case load(path) do
          {:ok, settings} ->
            cache_settings(path, settings)
            {:ok, settings}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_error(reason)
    end
  end

  @spec load(Path.t()) :: {:ok, Schema.t()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        load_from_string(content)

      {:error, reason} ->
        {:error, {:missing_kepler_config, path, reason}}
    end
  end

  @spec load_from_string(String.t()) :: {:ok, Schema.t()} | {:error, term()}
  def load_from_string(content) when is_binary(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) ->
        Schema.parse(decoded)

      {:ok, _decoded} ->
        {:error, :kepler_config_not_a_map}

      {:error, reason} ->
        {:error, {:kepler_config_parse_error, reason}}
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason) do
    case reason do
      {:invalid_kepler_config, message} ->
        "Invalid kepler.yml config: #{message}"

      {:missing_kepler_config, path, raw_reason} ->
        "Missing kepler.yml at #{path}: #{inspect(raw_reason)}"

      :kepler_config_not_a_map ->
        "Invalid kepler.yml config: root document must decode to a map"

      {:kepler_config_parse_error, raw_reason} ->
        "Failed to parse kepler.yml: #{inspect(raw_reason)}"

      other ->
        "Invalid kepler.yml config: #{inspect(other)}"
    end
  end

  defp cached_settings(path) do
    case {
      Application.get_env(:symphony_elixir, @settings_cache_key),
      Application.get_env(:symphony_elixir, @settings_source_cache_key)
    } do
      {%Schema{} = settings, ^path} -> {:ok, settings}
      _ -> :error
    end
  end

  defp cache_settings(path, %Schema{} = settings) do
    Application.put_env(:symphony_elixir, @settings_cache_key, settings)
    Application.put_env(:symphony_elixir, @settings_source_cache_key, path)
  end

  defp clear_cached_settings do
    Application.delete_env(:symphony_elixir, @settings_cache_key)
    Application.delete_env(:symphony_elixir, @settings_source_cache_key)
  end
end
