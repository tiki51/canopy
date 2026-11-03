defmodule Canopy.Playbooks.Sharing.TextTest do
  use ExUnit.Case, async: true

  alias Canopy.Playbooks.Sharing.Text

  @text "---\nname: bug-fix\ndescription: Fix it.\nsteps:\n  - id: a\n    title: A\n    owner: coordinator\n---\n\nGuidance.\n"

  test "the content hash ignores name, version, CRLF and trailing space" do
    hash = Text.content_hash(@text)

    assert Text.content_hash(Text.put_name(@text, "bug-fix-2")) == hash
    assert Text.content_hash(Text.put_version(@text, 7)) == hash
    assert Text.content_hash(String.replace(@text, "\n", "\r\n")) == hash
    assert Text.content_hash(String.replace(@text, "Guidance.", "Guidance.   ") <> "\n\n") == hash
    refute Text.content_hash(String.replace(@text, "Guidance.", "Other.")) == hash
  end

  test "put_version writes the line after name: and replaces an old one" do
    once = Text.put_version(@text, 3)
    assert once =~ "name: bug-fix\nversion: 3\ndescription:"
    twice = Text.put_version(once, 4)
    assert twice =~ "name: bug-fix\nversion: 4\ndescription:"
    refute twice =~ "version: 3"
    assert Text.strip_version(twice) == @text
  end

  test "only frontmatter lines are touched" do
    text = @text <> "\nname: not this\nversion: nor this\n"
    assert Text.strip_version(Text.put_version(text, 2)) == text
    assert Text.put_name(text, "other") =~ "name: not this"
    assert Text.put_name(text, "other") =~ "---\nname: other\n"
  end

  test "file_path" do
    assert Text.file_path("playbooks", "bug-fix") == "playbooks/bug-fix.md"
    assert Text.file_path("", "bug-fix") == "bug-fix.md"
  end
end
