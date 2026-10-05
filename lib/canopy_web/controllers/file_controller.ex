defmodule CanopyWeb.FileController do
  @moduledoc """
  Serves a shared document's bytes at `/files/:id/:filename`. The filename in
  the path is cosmetic (it names the download); the id decides what is sent.

  Images and PDFs are shown inline, everything else downloads, and every
  response is marked nosniff and, but for a PDF's inline view, sandboxed, so
  a document can never run as a page of Canopy's own origin. SVG downloads
  regardless of its kind because it can carry scripts. `?download=1`
  downloads any kind (the file viewer's Download buttons).

  A PDF shown inline goes without `sandbox`, which browsers' PDF viewers
  refuse to render in (the file viewer frames it). That is safe because
  the response is `application/pdf` with nosniff, so the browser only ever
  hands it to its PDF viewer, never parses it as a page; script inside a PDF
  runs in that viewer, not in Canopy's origin. Its CSP still keeps other
  sites from framing it.
  """

  use CanopyWeb, :controller

  alias Canopy.Documents
  alias Canopy.Documents.Store
  alias CanopyWeb.Download

  def show(conn, %{"id" => id} = params) do
    with %{} = document <- Documents.get(id),
         path = Store.path(document.id),
         true <- File.regular?(path) do
      inline? = inline?(document, params["download"] == "1")

      conn
      |> put_resp_content_type(document.mime, nil)
      |> put_resp_header("content-disposition", disposition(document, inline?))
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", csp(document, inline?))
      |> send_file(200, path)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(CanopyWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp inline?(%{kind: kind, mime: mime}, download?),
    do: not download? and kind in ["image", "pdf"] and mime != "image/svg+xml"

  defp disposition(document, inline?),
    do: Download.disposition(if(inline?, do: "inline", else: "attachment"), document.filename)

  defp csp(%{kind: "pdf", mime: "application/pdf"}, true), do: "frame-ancestors 'self'"
  defp csp(_document, _inline?), do: "sandbox"
end
