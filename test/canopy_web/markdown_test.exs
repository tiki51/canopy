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
    html = Markdown.to_html("<img src=/files/x> hi @backend", mentions: ["backend"])
    refute html =~ "<img"
    assert html =~ "@backend</span>"
  end

  test "only known names are highlighted as mentions, in any case" do
    html =
      Markdown.to_html("@Backend, @crew and @nobody", mentions: MapSet.new(["backend", "crew"]))

    assert html =~ ~s(<span class="#{Markdown.mention_class()}">@Backend</span>)
    assert html =~ ~s(<span class="#{Markdown.mention_class()}">@crew</span>)
    assert html =~ "and @nobody"
    refute Markdown.to_html("hi @backend") =~ "<span"

    assert Markdown.mention_parts("to @backend and @nobody: ok", ["backend"]) ==
             [{:plain, "to "}, {:mention, "@backend"}, {:plain, " and @nobody: ok"}]
  end

  test "a typed & before #name is not an entity, so the name is left alone" do
    html = Markdown.to_html("&#payments, but #payments", channels: %{"payments" => "ch_1"})
    assert html =~ "&amp;#payments, but <a "
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

  describe "previews" do
    test "plain/1 strips Markdown to one line of text" do
      body = """
      # Root cause

      **Root cause.** The `claim` step runs _after_ the charge:

      - first, see [the PR](https://x.test/1)
      - [x] then ![shot](/files/a.png)
      > quoted
      1. numbered

      ```elixir
      Payments.claim(invoice)
      ```
      ---
      """

      assert Markdown.plain(body) ==
               "Root cause Root cause. The claim step runs after the charge: first, see the PR " <>
                 "then shot quoted numbered Payments.claim(invoice)"
    end

    test "plain/1 keeps what only looks like Markdown" do
      assert Markdown.plain("rm *.ex *.exs in #billing, snake_case_name and @backend") ==
               "rm *.ex *.exs in #billing, snake_case_name and @backend"

      assert Markdown.plain("2 * 3 = 6") == "2 * 3 = 6"
    end

    test "plain/1 drops the unmatched markers of a cut fragment" do
      assert Markdown.plain("…the **Root cause is `claim") == "…the Root cause is claim"
      assert Markdown.plain(nil) == ""
      assert Markdown.plain("  \n ") == ""
    end

    test "preview_html/2 escapes everything but <code> and the match marks" do
      marks = {"\u0002", "\u0003"}

      html =
        "**\u0002Root\u0003 cause.** is `\u0002claim\u0003()` <b>x</b>\n- next"
        |> Markdown.preview_html(marks)
        |> Phoenix.HTML.safe_to_string()

      assert html ==
               "<mark>Root</mark> cause. is <code><mark>claim</mark>()</code> &lt;b&gt;x&lt;/b&gt; next"
    end

    test "preview_html/2 never leaves an unbalanced mark or a raw tag" do
      marks = {"\u0002", "\u0003"}

      html =
        "\u0002open `code\u0003 here` <script>alert(1)</script>"
        |> Markdown.preview_html(marks)
        |> Phoenix.HTML.safe_to_string()

      refute html =~ "<script"
      refute html =~ "\u0002"
      refute html =~ "\u0003"

      assert length(String.split(html, "<mark>")) == length(String.split(html, "</mark>"))
    end

    test "preview_html/3 with markdown: false keeps the text as written" do
      marks = {"\u0002", "\u0003"}

      html =
        "def __init__(self):\n    **kwargs \u0002hit\u0003"
        |> Markdown.preview_html(marks, markdown: false)
        |> Phoenix.HTML.safe_to_string()

      assert html == "def __init__(self): **kwargs <mark>hit</mark>"
    end
  end
end
