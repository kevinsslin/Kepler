defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc false

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

      {:more, body, conn} ->
        read_remaining_body(conn, body, opts)
    end
  end

  defp read_remaining_body(conn, acc, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        full_body = acc <> body
        {:ok, full_body, Plug.Conn.assign(conn, :raw_body, full_body)}

      {:more, body, conn} ->
        read_remaining_body(conn, acc <> body, opts)
    end
  end
end
