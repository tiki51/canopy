defmodule Canopy.Messages.CodeMaskTest do
  use ExUnit.Case, async: true

  alias Canopy.Messages.CodeMask

  defp mask(text), do: CodeMask.mask(text)

  test "text without code comes back unchanged" do
    assert mask("hi @reviewer, see #payments") == "hi @reviewer, see #payments"
    assert mask("") == ""
  end

  test "inline spans are blanked byte for byte, delimiters included" do
    assert mask("a `@x` b") == "a      b"
    assert mask("``a ` b`` c") == "          c"
    # é is two bytes; the size never changes, so offsets still line up
    text = "`é` @x"
    assert byte_size(mask(text)) == byte_size(text)
    assert mask(text) == "     @x"
  end

  test "a run with no closer, or an escaped backtick, is literal" do
    assert mask("a ` b @x") == "a ` b @x"
    assert mask("``a` @x") == "``a` @x"
    assert mask("\\`@x\\`") == "\\`@x\\`"
  end

  test "a blank line ends the paragraph a span must close in" do
    assert mask("`a\n\n@x `b`") == "`a\n\n@x    "
    assert mask("`a\n@x` y") == "       y"
  end

  test "fenced blocks run to a matching fence, or to the end" do
    assert mask("```\n@x\n```\n@y") == "          \n@y"
    assert mask("~~~ sh\n@x\n~~~\n@y") == String.duplicate(" ", 13) <> "\n@y"
    assert mask("````\n```\n@x\n````") == String.duplicate(" ", 16)
    assert mask("```\n@x") == "      "
    assert mask("- a\n  ```\n  @x\n  ```") == "- a\n" <> String.duplicate(" ", 16)
  end

  test "a backtick fence's info string has no backticks" do
    # "``` `a` ```" on one line is an inline span, not a fence
    assert mask("``` `a` ```\n@x") == "           \n@x"
  end

  test "runs with no closer stay literal, and fast" do
    # every run length appears once, so each opener searches to the end
    text = Enum.map_join(1..200, " @x ", &String.duplicate("`", &1))
    {micros, masked} = :timer.tc(fn -> mask(text) end)
    assert masked == text
    assert micros < 500_000
  end
end
