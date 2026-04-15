defmodule SymphonyElixirWeb.KeplerWebhookController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.ControlPlane
  alias SymphonyElixir.RuntimeMode

  @max_timestamp_skew_ms 60_000

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) when is_map(params) do
    cond do
      not RuntimeMode.kepler?() ->
        send_resp(conn, 404, "")

      not valid_signature?(conn, params) ->
        send_resp(conn, 401, "")

      true ->
        case ControlPlane.handle_webhook(params) do
          :ok ->
            send_resp(conn, 200, "")

          {:error, {:invalid_payload, _reason}} ->
            send_resp(conn, 400, "")

          {:error, :unavailable} ->
            send_resp(conn, 503, "")
        end
    end
  end

  defp valid_signature?(conn, params) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = get_req_header(conn, "linear-signature") |> List.first()
    webhook_timestamp = params["webhookTimestamp"] || get_in(params, ["data", "webhookTimestamp"])

    with true <- is_binary(signature),
         true <- fresh_timestamp?(webhook_timestamp),
         computed when is_binary(computed) <- expected_signature(raw_body),
         true <- secure_compare_signature(signature, computed) do
      true
    else
      _ -> false
    end
  end

  defp fresh_timestamp?(value) when is_integer(value) do
    abs(System.system_time(:millisecond) - value) <= @max_timestamp_skew_ms
  end

  defp fresh_timestamp?(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> fresh_timestamp?(timestamp)
      _ -> false
    end
  end

  defp fresh_timestamp?(_value), do: false

  defp expected_signature(raw_body) do
    :crypto.mac(:hmac, :sha256, Config.settings!().linear.webhook_secret, raw_body)
    |> Base.encode16(case: :lower)
  end

  defp secure_compare_signature(left, right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end
end
