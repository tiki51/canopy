defmodule CanopyWeb.LoopbackHost do
  @moduledoc """
  Answers only requests addressed to this machine by a loopback name.

  Canopy has no login and listens on 127.0.0.1, but listening on loopback
  alone does not keep other sites out: a page anywhere can point a name it
  controls at 127.0.0.1 (DNS rebinding) and drive the UI and the MCP endpoint
  through the browser. Such a request still carries that name in its Host
  header, so anything not addressed to `127.0.0.1`, `localhost`, or `::1` is
  refused. A request relayed by a tunnel or proxy (`Forwarded` or
  `X-Forwarded-*` headers) is refused too: whoever reached the tunnel would
  otherwise reach the whole workspace.

  `CANOPY_BIND` (dev only) turns the check off, since the user chose to show
  Canopy on their network (`config :canopy, :host_check`). Tests add the
  host `Phoenix.ConnTest` uses through `config :canopy, :extra_hosts`.

  LiveView's websocket is matched by the endpoint before any plug runs; it is
  guarded by `check_origin` instead (`config/runtime.exs`).
  """

  @behaviour Plug

  import Plug.Conn

  @loopback ~w(127.0.0.1 localhost ::1 [::1])
  @relay_headers ~w(forwarded x-forwarded-for x-forwarded-host x-forwarded-proto)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if allowed?(conn) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Canopy only answers requests to 127.0.0.1 or localhost.\n")
      |> halt()
    end
  end

  defp allowed?(conn) do
    not Application.get_env(:canopy, :host_check, true) or
      (conn.host in (@loopback ++ Application.get_env(:canopy, :extra_hosts, [])) and
         not relayed?(conn))
  end

  defp relayed?(conn), do: Enum.any?(@relay_headers, &(get_req_header(conn, &1) != []))
end
