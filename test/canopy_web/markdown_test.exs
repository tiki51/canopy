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

  test "#channel references become in-app links only for known channels" do
    channels = %{"payments" => "ch_1"}

    html =
      Markdown.to_html("see #payments and #unknown, not `#payments` in code, colour #0b1a33",
        channels: channels
      )

    assert html =~
             ~s(<a href="/channels/ch_1" data-phx-link="redirect" data-phx-link-state="push" class=")

    assert html =~ ">#payments</a> and #unknown"
    assert html =~ "<code>#payments</code>"
    assert html =~ "colour #0b1a33"
    refute Markdown.to_html("see #payments") =~ "<a"
    # never inside another link
    html = Markdown.to_html("[#payments](https://x.example/)", channels: channels)
    assert Regex.scan(~r/<a /, html) |> length() == 1
  end
end
