defmodule CanopyWeb.Download do
  @moduledoc """
  Response headers for files Canopy hands out: an RFC 6266
  `content-disposition` with a plain-ASCII `filename=` for old clients and
  the exact name as `filename*=`, `nosniff`, and a sandbox CSP.
  """

  import Plug.Conn

  @doc "`inline` or `attachment`, naming the file."
  def disposition(type, filename) when type in ["inline", "attachment"] do
    ~s(#{type}; filename="#{ascii_name(filename)}"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)})
  end

  @doc "Sends `body` as a download named `filename`, of `content_type`."
  def send_attachment(conn, filename, content_type, body) do
    conn
    |> put_resp_content_type(content_type, nil)
    |> put_resp_header("content-disposition", disposition("attachment", filename))
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "sandbox")
    |> send_resp(200, body)
  end

  # The plain `filename=` value is for old clients: ASCII only, no quotes.
  defp ascii_name(name) do
    name
    |> String.replace(~r/[^\x20-\x7e]/u, "_")
    |> String.replace(~s("), "_")
  end
end
