defmodule CanopyWeb.FileControllerTest do
  use CanopyWeb.ConnCase, async: false

  import Canopy.Fixtures

  alias Canopy.Documents

  @png File.read!(Path.expand("../../support/files/red.png", __DIR__))

  defp create(attrs) do
    {:ok, doc} =
      attrs
      |> Map.put_new(:user_id, user_fixture().id)
      |> then(&Documents.create/1)

    doc
  end

  test "an image is served inline with strict headers", %{conn: conn} do
    doc = create(%{filename: "shot one.png", mime: "image/png", source: {:binary, @png}})
    conn = get(conn, Documents.url_path(doc))

    assert conn.status == 200
    assert conn.resp_body == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^inline; filename="shot one.png"; filename\*=UTF-8''shot%20one.png$/
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
    assert [cache] = get_resp_header(conn, "cache-control")
    assert cache =~ "immutable"
  end

  test "text downloads, and the path filename is cosmetic", %{conn: conn} do
    doc = create(%{filename: "report.md", source: {:binary, "# hi"}})
    conn = get(conn, "/files/#{doc.id}/whatever.txt")
    assert conn.status == 200
    assert conn.resp_body == "# hi"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^attachment; filename="report.md"/
    assert get_resp_header(conn, "content-type") == ["text/markdown"]
  end

  test "svg never renders inline", %{conn: conn} do
    doc = create(%{filename: "logo.svg", mime: "image/svg+xml", source: {:binary, "<svg/>"}})
    conn = get(conn, Documents.url_path(doc))
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^attachment/
  end

  test "unknown ids and missing bytes are 404", %{conn: conn} do
    conn = get(conn, "/files/doc_nope/x.png")
    assert conn.status == 404

    doc = create(%{filename: "gone.txt", source: {:binary, "x"}})
    :ok = Documents.Store.delete(doc.id)
    conn = get(build_conn(), Documents.url_path(doc))
    assert conn.status == 404
  end
end
