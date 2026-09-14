defmodule Canopy.MCP.AuthPlug do
  @moduledoc """
  Authenticates callers of the MCP endpoint.

  Two bearer tokens are accepted. The settings token (`Canopy.Settings.get().mcp_token`)
  proves the caller is the OpenCode server Canopy registered with; agent
  identity is then resolved from the plugin-stamped `canopy_session_id`. A
  session token (`agent_sessions.mcp_token`) is what a Claude Code process
  presents; it names the session outright, and the identity is assigned as
  `:canopy_session` for `Canopy.MCP.Identity` to read from the frame.
  """

  @behaviour Plug

  import Plug.Conn

  alias Canopy.{AgentSessions, Settings}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, conn} <- authenticate(conn, token) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{"error" => "unauthorized"}))
        |> halt()
    end
  end

  defp authenticate(conn, token) do
    cond do
      Plug.Crypto.secure_compare(token, Settings.mcp_token()) ->
        {:ok, assign(conn, :mcp_authenticated, true)}

      session = AgentSessions.get_by_mcp_token(token) ->
        {:ok,
         conn
         |> assign(:mcp_authenticated, true)
         |> assign(:canopy_session, %{
           engine: session.engine,
           engine_session_id: session.engine_session_id
         })}

      true ->
        :error
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
