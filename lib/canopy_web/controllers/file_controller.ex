defmodule CanopyWeb.FileController do
  @moduledoc """
  Serves a shared document's bytes at `/files/:id/:filename`. The filename in
  the path is cosmetic (it names the download); the id decides what is sent.

  Images and PDFs are shown inline, everything else downloads, and every
  response is sandboxed and marked nosniff so a document can never run as a
  page of Canopy's own origin. SVG downloads regardless of its kind because
  it can carry scripts.
  """

  use CanopyWeb, :controller

  alias Canopy.Documents
  alias Canopy.Documents.Store

  def show(conn, %{"id" => id}) do
    with %{} = document <- Documents.get(id),
         path = Store.path(document.id),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type(document.mime, nil)
      |> put_resp_header("content-disposition", disposition(document))
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox")
      |> send_file(200, path)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(CanopyWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp disposition(%{kind: kind, mime: mime} = document) do
    inline? = kind in ["image", "pdf"] and mime != "image/svg+xml"
    type = if inline?, do: "inline", else: "attachment"

    ~s(#{type}; filename="#{ascii_name(document.filename)}"; filename*=UTF-8''#{URI.encode(document.filename, &URI.char_unreserved?/1)})
  end

  # The plain `filename=` value is for old clients: ASCII only, no quotes.
  defp ascii_name(name) do
    name
    |> String.replace(~r/[^\x20-\x7e]/u, "_")
    |> String.replace(~s("), "_")
  end
end
