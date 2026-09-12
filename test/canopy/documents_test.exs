defmodule Canopy.DocumentsTest do
  use Canopy.DataCase, async: true

  import Canopy.Fixtures

  alias Canopy.Documents
  alias Canopy.Documents.Store

  @png File.read!(Path.expand("../support/files/red.png", __DIR__))
  @md_path Path.expand("../support/files/report.md", __DIR__)

  describe "create/1" do
    test "stores bytes from a binary and derives kind, size, and sha" do
      user = user_fixture()

      {:ok, doc} =
        Documents.create(%{
          filename: "shot.png",
          mime: "image/png",
          source: {:binary, @png},
          user_id: user.id
        })

      assert doc.kind == "image"
      assert doc.byte_size == byte_size(@png)
      assert doc.sha256 == Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
      assert String.starts_with?(doc.id, "doc_")
      assert Store.exists?(doc.id)
      assert {:ok, @png} = Documents.read(doc)
    end

    test "copies bytes from a path and keeps the source" do
      agent = agent_fixture()

      {:ok, doc} =
        Documents.create(%{filename: "report.md", source: {:path, @md_path}, agent_id: agent.id})

      assert doc.kind == "text"
      assert doc.mime == "text/markdown"
      assert File.exists?(@md_path)
      assert {:ok, text, total} = Documents.read_text(doc)
      assert text =~ "PELICAN-42"
      assert total == String.length(File.read!(@md_path))
    end

    test "sniffs the type when the client sends a generic one" do
      {:ok, doc} =
        Documents.create(%{
          filename: "blob",
          mime: "application/octet-stream",
          source: {:binary, @png},
          user_id: user_fixture().id
        })

      assert doc.mime == "image/png"
      assert doc.kind == "image"
    end

    test "treats unknown UTF-8 as text and binary junk as other" do
      {:ok, text} =
        Documents.create(%{
          filename: "notes",
          source: {:binary, "plain words"},
          user_id: user_fixture().id
        })

      assert text.mime == "text/plain"
      assert text.kind == "text"

      {:ok, bin} =
        Documents.create(%{
          filename: "dump.bin",
          source: {:binary, <<0, 1, 2, 255>>},
          user_id: user_fixture().id
        })

      assert bin.mime == "application/octet-stream"
      assert bin.kind == "other"
    end

    test "sanitises filenames" do
      {:ok, doc} =
        Documents.create(%{
          filename: "../../etc/pass\nwd.txt",
          source: {:binary, "x"},
          user_id: user_fixture().id
        })

      assert doc.filename == "passwd.txt"
      assert Documents.safe_filename("") == "file"
      assert Documents.safe_filename(nil) == "file"
      assert Documents.safe_filename(".hidden") == "hidden"
      assert Documents.safe_filename("C:\\shots\\one.png") == "one.png"
    end

    test "rejects files over the limit without writing anything" do
      big = :binary.copy("a", Documents.max_bytes() + 1)

      assert {:error, :too_large} =
               Documents.create(%{
                 filename: "big.txt",
                 source: {:binary, big},
                 user_id: user_fixture().id
               })

      assert Documents.count() == 0
    end

    test "requires exactly one uploader" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Documents.create(%{filename: "a.txt", source: {:binary, "a"}})

      assert "exactly one of agent_id or user_id must be set" in errors_on(changeset).user_id
      assert Documents.count() == 0
    end

    test "a missing source path is unreadable" do
      assert {:error, :unreadable} =
               Documents.create(%{
                 filename: "gone",
                 source: {:path, "/nope/gone"},
                 user_id: user_fixture().id
               })
    end
  end

  describe "list/1 and delete/1" do
    test "filters by search and kind, newest first" do
      user = user_fixture()

      {:ok, a} =
        Documents.create(%{filename: "alpha.md", source: {:binary, "a"}, user_id: user.id})

      {:ok, b} =
        Documents.create(%{filename: "beta.png", source: {:binary, @png}, user_id: user.id})

      assert Enum.map(Documents.list(), & &1.id) == [b.id, a.id]
      assert Enum.map(Documents.list(search: "alph"), & &1.id) == [a.id]
      assert Enum.map(Documents.list(kind: "image"), & &1.id) == [b.id]
      assert Documents.list(search: "%") == []
    end

    test "delete removes the row and the bytes and broadcasts" do
      Documents.subscribe()

      {:ok, doc} =
        Documents.create(%{filename: "x.txt", source: {:binary, "x"}, user_id: user_fixture().id})

      assert {:ok, _} = Documents.delete(doc)
      refute Store.exists?(doc.id)
      assert Documents.get(doc.id) == nil
      assert_receive {:document_deleted, id, []}
      assert id == doc.id
    end
  end

  describe "helpers" do
    test "size_label" do
      assert Documents.size_label(512) == "512 B"
      assert Documents.size_label(12 * 1024) == "12 KB"
      assert Documents.size_label(3_500_000) == "3.3 MB"
    end

    test "prompt_mime sends text as text/plain" do
      assert Documents.prompt_mime(%Documents.Document{kind: "text", mime: "text/markdown"}) ==
               "text/plain"

      assert Documents.prompt_mime(%Documents.Document{kind: "image", mime: "image/png"}) ==
               "image/png"
    end

    test "data_url and url_path" do
      {:ok, doc} =
        Documents.create(%{
          filename: "a b.md",
          source: {:binary, "hi"},
          user_id: user_fixture().id
        })

      assert {:ok, "data:text/plain;base64,aGk="} = Documents.data_url(doc)
      assert Documents.url_path(doc) == "/files/#{doc.id}/a%20b.md"
    end

    test "materialize copies into the repository workspace once" do
      repo = repository_fixture()

      {:ok, doc} =
        Documents.create(%{filename: "r.md", source: {:binary, "hi"}, user_id: user_fixture().id})

      assert {:ok, path} = Documents.materialize(doc, repo.path)
      assert path == Path.join(repo.path, Documents.materialized_relative_path(doc))
      assert File.read!(path) == "hi"
      assert {:ok, ^path} = Documents.materialize(doc, repo.path)
    end
  end

  describe "prompt_plan/1" do
    test "parts for small images and text, paths otherwise, three parts at most" do
      doc = fn kind, size -> %Documents.Document{id: kind, kind: kind, byte_size: size} end

      plan =
        Documents.prompt_plan([
          doc.("image", 100),
          doc.("text", 100),
          doc.("pdf", 100),
          doc.("image", 6 * 1024 * 1024),
          doc.("text", 65 * 1024),
          doc.("text", 10),
          doc.("image", 10)
        ])

      assert Enum.map(plan, fn {d, mode} -> {d.kind, mode} end) == [
               {"image", :part},
               {"text", :part},
               {"pdf", :path},
               {"image", :path},
               {"text", :path},
               {"text", :part},
               {"image", :path}
             ]
    end
  end
end
