defmodule SymphonyElixirWeb.KeplerApiController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.ControlPlane
  alias SymphonyElixir.RuntimeMode

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    case RuntimeMode.current() do
      :kepler ->
        settings_result = Config.settings()
        config_loaded? = match?({:ok, _settings}, settings_result)
        control_plane_ready? = not is_nil(Process.whereis(ControlPlane))
        ready? = config_loaded? and control_plane_ready?

        conn
        |> put_status(if(ready?, do: 200, else: 503))
        |> json(%{mode: "kepler", ok: ready?})

      :workflow ->
        json(conn, %{mode: "workflow", ok: true})
    end
  end

  @spec runs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def runs(conn, _params) do
    if RuntimeMode.kepler?() do
      with {:ok, settings} <- Config.settings(),
           :ok <- authorize_runs_request(conn, settings.server.api_token) do
        json(conn, ControlPlane.snapshot())
      else
        :disabled -> send_resp(conn, 404, "")
        :error -> send_resp(conn, 401, "")
        {:error, _reason} -> send_resp(conn, 503, "")
      end
    else
      send_resp(conn, 404, "")
    end
  end

  @spec oauth_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def oauth_callback(conn, _params) do
    send_resp(
      conn,
      200,
      "Kepler received the Linear OAuth redirect. Runtime GraphQL auth is handled separately by configured server credentials."
    )
  end

  defp authorize_runs_request(_conn, nil), do: :disabled
  defp authorize_runs_request(_conn, ""), do: :disabled

  defp authorize_runs_request(conn, expected_token) when is_binary(expected_token) do
    if api_token_matches?(supplied_api_token(conn), expected_token) do
      :ok
    else
      :error
    end
  end

  defp supplied_api_token(conn) do
    bearer_header_token(conn) || request_header_token(conn, "x-kepler-api-token")
  end

  defp bearer_header_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      ["bearer " <> token] -> token
      _ -> nil
    end
  end

  defp request_header_token(conn, header) do
    conn
    |> get_req_header(header)
    |> List.first()
  end

  defp api_token_matches?(supplied_token, expected_token)
       when is_binary(supplied_token) and is_binary(expected_token) and
              byte_size(supplied_token) == byte_size(expected_token) do
    Plug.Crypto.secure_compare(supplied_token, expected_token)
  end

  defp api_token_matches?(_, _), do: false
end
