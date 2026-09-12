defmodule CanopyWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias CanopyWeb.Markdown

  test "local images are kept and get lazy loading" do
    html = Markdown.to_html("![shot](/files/doc_1/shot.png)")

    assert html =~
             ~s(<img loading="lazy" class="message-image" src="/files/doc_1/shot.png" alt="shot" />)
  end

  test "remote images become links" do
    html =
      Markdown.to_html("![tracker](https://evil.example/p.gif) and ![](https://x.example/y.png)")

    refute html =~ "<img"

    assert html =~
             ~s(<a target="_blank" rel="noopener noreferrer" href="https://evil.example/p.gif">tracker</a>)

    assert html =~ ~s(href="https://x.example/y.png">https://x.example/y.png</a>)
  end

  test "raw html stays escaped and mentions are highlighted" do
    html = Markdown.to_html("<img src=/files/x> hi @backend")
    refute html =~ "<img"
    assert html =~ "@backend</span>"
  end
end
