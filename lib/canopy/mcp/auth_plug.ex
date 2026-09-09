defmodule Canopy.MCP.AuthPlug do
  @moduledoc """
  Authenticates the OpenCode server to the MCP endpoint.

  The bearer token must equal `Canopy.Settings.get().mcp_token`. This proves
  the caller is the OpenCode server Canopy registered with; agent identity is
  resolved separately from the plugin-stamped `canopy_session_id`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Canopy.Settings

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         true <- Plug.Crypto.secure_compare(token, Settings.mcp_token()) do
      assign(conn, :mcp_authenticated, true)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{"error" => "unauthorized"}))
        |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] when byte_size(token) > 0 ->
            if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}, else: :error

          _ ->
            :error
        end

      [] ->
        :error
    end
  end
end
