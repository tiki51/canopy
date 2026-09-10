defmodule CanopyWeb.TimelineComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CanopyWeb.TimelineComponents

  defp render_body(body, opts \\ []) do
    assigns = %{body: body, inline: Keyword.get(opts, :inline, false)}

    rendered_to_string(~H"""
    <TimelineComponents.message_text body={@body} inline={@inline} />
    """)
  end

  test "markdown renders lists, code, tables and line breaks" do
    html =
      render_body("""
      @Steven

      Prioritize these:
      1. Add idempotency (`payments.py:21`)
      2. One retry owner

      ```python
      def charge(): pass
      ```

      | option | cost |
      |---|---|
      | a | low |

      first line
      second line
      """)

    assert html =~ ~s(class="message-body break-words">)
    assert html =~ ~s(<ol>\n<li>Add idempotency \(<code>payments.py:21</code>\))
    assert html =~ ~s(<pre><code class="language-python">def charge\(\): pass\n</code></pre>)
    assert html =~ ~s(<table>) and html =~ ~s(<td>low</td>)
    assert html =~ ~s(first line<br />\nsecond line)
  end

  test "mentions are highlighted outside code and left alone inside it" do
    html = render_body("ping @reviewer, not `@reviewer` and not\n```\n@reviewer\n```")

    assert html =~
             ~s(ping <span class="rounded bg-secondary/10 px-1 font-medium text-secondary">@reviewer</span>, not <code>@reviewer</code>)

    assert html =~ ~s(<pre><code>@reviewer\n</code></pre>)
    assert length(String.split(html, "<span class=")) == 2
  end

  test "raw html is escaped and unsafe links are neutralised" do
    html = render_body("<script>alert(1)</script> <b>bold?</b> [x](javascript:alert(1))")

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<b>"
    refute html =~ ~s(href="javascript)
    refute html =~ "<a "
  end

  test "links open in a new tab" do
    html = render_body("see https://example.com/docs")

    assert html =~
             ~s(<a target="_blank" rel="noopener noreferrer" href="https://example.com/docs">https://example.com/docs</a>)
  end

  test "inline bodies keep the text as written and highlight mentions" do
    html = render_body("handed off to @reviewer: **not bold**", inline: true)

    assert html =~
             ~s(handed off to <span class="rounded bg-secondary/10 px-1 font-medium text-secondary">@reviewer</span>: **not bold**</span>)

    refute html =~ "<strong>"
    refute html =~ ~r/<span[^>]*>\s/
  end

  test "a nil body renders nothing" do
    assert render_body(nil) =~ ~s(class="message-body break-words"></div>)
  end
end
