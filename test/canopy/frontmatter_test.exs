defmodule Canopy.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Canopy.Frontmatter

  describe "split/2" do
    test "accepts a BOM and CRLF line ends, and keeps a --- inside the body" do
      text = "﻿---\r\nname: x\r\n---\r\nintro\r\n---\r\nmore\r\n"
      assert {:ok, "name: x", body} = Frontmatter.split(text)
      assert body == "intro\n---\nmore\n"
    end

    test "frontmatter alone, with no body" do
      assert {:ok, "a: 1", ""} = Frontmatter.split("---\na: 1\n---")
    end

    test "text without frontmatter is refused, naming the document" do
      assert {:error, [reason]} = Frontmatter.split("# hello", "the template")
      assert reason =~ "the template must start with YAML frontmatter"
    end
  end

  describe "read/4" do
    test "refuses anchors and aliases before parsing" do
      text = "---\nbase: &b hello\ncopy: *b\n---\n"
      assert {:error, [reason]} = Frontmatter.read(text, "the file", 10_000, 1_000)
      assert reason =~ "anchors and aliases"
    end

    test "caps the text and the frontmatter before parsing" do
      assert {:error, [reason]} =
               Frontmatter.read(
                 "---\na: 1\n---\n" <> String.duplicate("x", 100),
                 "the file",
                 50,
                 1_000
               )

      assert reason =~ "the file is too long"

      assert {:error, [reason]} =
               Frontmatter.read(
                 "---\na: #{String.duplicate("x", 100)}\n---\n",
                 "the file",
                 10_000,
                 50
               )

      assert reason =~ "the frontmatter is too long"
    end

    test "non-map frontmatter is rejected" do
      assert {:error, [reason]} =
               Frontmatter.read("---\n- a\n- b\n---\n", "the file", 1_000, 1_000)

      assert reason =~ "key: value"

      assert {:error, [reason]} =
               Frontmatter.read("---\njust text\n---\n", "the file", 1_000, 1_000)

      assert reason =~ "key: value"
    end

    test "invalid YAML is one readable line" do
      assert {:error, ["invalid YAML: " <> _]} =
               Frontmatter.read("---\nname: [abc\n---\n", "the file", 1_000, 1_000)
    end
  end

  describe "encode/1" do
    test "awkward scalars survive a round trip through the parser" do
      values = [
        "#dc2626",
        "a: b",
        ~s(say "hi"),
        "it's",
        "@backend",
        "yes",
        "No",
        "null",
        "~",
        "1.0",
        "42",
        "0x1f",
        "- dash",
        "[list]",
        "{map}",
        "*star",
        "&amp",
        "!tag",
        "%percent",
        "trailing ",
        " leading",
        "multi\nline",
        "back\\slash",
        "tab\there",
        "naïve café — 日本語 🚀",
        "Bash(git diff *)",
        "plain words, with commas"
      ]

      fields = values |> Enum.with_index() |> Enum.map(fn {v, i} -> {"k#{i}", v} end)
      yaml = Frontmatter.encode(fields)
      assert {:ok, parsed} = Frontmatter.parse(yaml)

      for {key, value} <- fields, do: assert(parsed[key] == value, "#{key}: #{inspect(value)}")
    end

    test "plain text stays plain; integers, booleans and lists are written as such" do
      yaml =
        Frontmatter.encode(
          canopy_template: 1,
          name: "backend",
          seed: true,
          skip: nil,
          tools: ["Bash(git *)", "Read"],
          members: [[name: "backend", role: nil], [name: "test", role: "test"]]
        )

      assert yaml =~ "name: backend\n"
      refute yaml =~ "skip"

      assert {:ok,
              %{
                "canopy_template" => 1,
                "seed" => true,
                "tools" => ["Bash(git *)", "Read"],
                "members" => [%{"name" => "backend"}, %{"name" => "test", "role" => "test"}]
              }} = Frontmatter.parse(yaml)
    end

    test "document/2 puts the frontmatter between --- lines before the body" do
      text = Frontmatter.document([name: "x"], "Body\n---\nmore")
      assert {:ok, "name: x", body} = Frontmatter.split(text)
      assert String.trim(body) == "Body\n---\nmore"
    end
  end
end
