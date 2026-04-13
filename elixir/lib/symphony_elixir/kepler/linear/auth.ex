defmodule SymphonyElixir.Kepler.Linear.Auth do
  @moduledoc """
  Resolves Linear runtime authentication for Kepler.

  Preferred mode is OAuth client credentials using the Linear app itself.
  `linear.api_key` remains available as a fallback for staging or migration.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Config.Schema

  @name __MODULE__
  @call_timeout_ms 15_000
  @refresh_skew_ms 60_000

  defmodule State do
    @moduledoc false

    defstruct token: nil,
              expires_at_ms: nil,
              token_type: "Bearer",
              cache_key: nil
  end

  @type headers_result :: {:ok, [{String.t(), String.t()}]} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec headers() :: headers_result()
  def headers do
    GenServer.call(@name, :headers, @call_timeout_ms)
  catch
    :exit, reason -> {:error, {:linear_auth_unavailable, reason}}
  end

  @spec invalidate_token() :: :ok
  def invalidate_token do
    case Process.whereis(@name) do
      nil -> :ok
      _pid -> GenServer.cast(@name, :invalidate_token)
    end

    :ok
  end

  @spec reset() :: :ok
  def reset do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    :ok
  end

  @spec auth_mode() :: Schema.linear_auth_mode()
  def auth_mode do
    Config.settings!().linear
    |> Schema.linear_auth_mode()
  end

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_call(:headers, _from, state) do
    linear_settings = Config.settings!().linear
    state = maybe_reset_cache(state, linear_settings)

    case Schema.linear_auth_mode(linear_settings) do
      :api_key ->
        {:reply,
         {:ok,
          [
            {"Authorization", linear_settings.api_key},
            {"Content-Type", "application/json"}
          ]}, state}

      :client_credentials ->
        case ensure_token(state, linear_settings) do
          {:ok, headers, next_state} -> {:reply, {:ok, headers}, next_state}
          {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
        end

      :unconfigured ->
        {:reply, {:error, :missing_linear_api_token}, state}
    end
  end

  @impl true
  def handle_cast(:invalidate_token, %State{} = state) do
    {:noreply, %State{state | token: nil, expires_at_ms: nil, token_type: "Bearer"}}
  end

  defp maybe_reset_cache(%State{} = state, linear_settings) do
    cache_key = cache_key(linear_settings)

    if state.cache_key == cache_key do
      state
    else
      %State{state | token: nil, expires_at_ms: nil, token_type: "Bearer", cache_key: cache_key}
    end
  end

  defp ensure_token(%State{} = state, linear_settings) do
    if token_valid?(state) do
      {:ok, bearer_headers(state.token, state.token_type), state}
    else
      case fetch_client_credentials_token(linear_settings) do
        {:ok, access_token, token_type, expires_at_ms} ->
          next_state = %State{
            state
            | token: access_token,
              token_type: token_type,
              expires_at_ms: expires_at_ms
          }

          {:ok, bearer_headers(access_token, token_type), next_state}

        {:error, reason} ->
          {:error, reason, %State{state | token: nil, expires_at_ms: nil, token_type: "Bearer"}}
      end
    end
  end

  defp fetch_client_credentials_token(linear_settings) do
    auth_header =
      "Basic " <>
        Base.encode64("#{linear_settings.client_id}:#{linear_settings.client_secret}", padding: false)

    headers = [
      {"Authorization", auth_header},
      {"Content-Type", "application/x-www-form-urlencoded"}
    ]

    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "scope" => Enum.join(linear_settings.oauth_scopes, ",")
      })

    case http_client_module().post(linear_settings.oauth_token_url, headers: headers, body: body) do
      {:ok, %{status: 200, body: response_body}} ->
        decode_token_response(response_body)

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Kepler Linear OAuth token request failed status=#{status} body=#{summarize_body(response_body)}")

        {:error, {:linear_oauth_status, status}}

      {:error, reason} ->
        Logger.error("Kepler Linear OAuth token request failed: #{inspect(reason)}")
        {:error, {:linear_oauth_request, reason}}
    end
  end

  defp decode_token_response(%{"access_token" => access_token} = body) when is_binary(access_token) do
    token_type =
      body
      |> Map.get("token_type", "Bearer")
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "Bearer"
        value -> value
      end

    expires_in_seconds =
      body
      |> Map.get("expires_in", 0)
      |> normalize_expires_in()

    expires_at_ms = System.system_time(:millisecond) + expires_in_seconds * 1_000

    {:ok, access_token, token_type, expires_at_ms}
  end

  defp decode_token_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_token_response(decoded)
      {:error, reason} -> {:error, {:linear_oauth_decode, reason}}
    end
  end

  defp decode_token_response(_body), do: {:error, :invalid_linear_oauth_response}

  defp normalize_expires_in(value) when is_integer(value) and value > 0, do: value

  defp normalize_expires_in(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 2_592_000
    end
  end

  defp normalize_expires_in(_value), do: 2_592_000

  defp bearer_headers(access_token, token_type) do
    [
      {"Authorization", "#{token_type} #{access_token}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp token_valid?(%State{token: token, expires_at_ms: expires_at_ms})
       when is_binary(token) and is_integer(expires_at_ms) do
    expires_at_ms - System.system_time(:millisecond) > @refresh_skew_ms
  end

  defp token_valid?(_state), do: false

  defp cache_key(linear_settings) do
    {
      Config.config_file_path(),
      linear_settings.endpoint,
      linear_settings.client_id,
      linear_settings.oauth_token_url,
      linear_settings.oauth_scopes
    }
  end

  defp summarize_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
    |> inspect()
  end

  defp summarize_body(body) when is_map(body), do: inspect(body, limit: 20, printable_limit: 500)
  defp summarize_body(body), do: inspect(body)

  defp http_client_module do
    Application.get_env(:symphony_elixir, :kepler_linear_http_client_module, Req)
  end
end
