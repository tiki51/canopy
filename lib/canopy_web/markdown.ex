defmodule CanopyWeb.Markdown do
  @moduledoc """
  Renders message bodies written in GitHub-flavoured Markdown to safe HTML.

  Raw HTML in the source is escaped rather than passed through, dangerous link
  schemes are dropped by the renderer, and single newlines become line breaks
  so chat-style messages keep their shape. `@mentions` of known agents and
  teams outside code are wrapped in a highlight span after rendering.

  Images are kept only when they point at a document Canopy serves itself
  (`/files/…`); any other image source becomes a plain link, so a message can
  never make the browser fetch a remote picture.
  """

  @mention_regex ~r/((?<![\w@])@[a-z0-9][a-z0-9_-]*)/i
  @tag_regex ~r/(<[^>]+>)/

  @mdex_opts [
    extension: [strikethrough: true, table: true, tasklist: true, autolink: true],
    render: [escape: true, hardbreaks: true],
    syntax_highlight: nil
  ]

  @doc """
  Markdown to HTML. Returns an empty string for anything that is not a binary.

  Options:

    * `channels: %{"name" => channel_id}` turns `#name` references outside
      code and links into in-app links to those channels; unknown names are
      left as text.
    * `mentions: names` (lowercase agent and team names) highlights `@name`
      outside code when the name is one of them, the same names the composer
      highlights; any other `@word` is left as text. Without it nothing is
      highlighted.
  """
  @spec to_html(term, keyword) :: String.t()
  def to_html(body, opts \\ [])

  def to_html(body, opts) when is_binary(body) do
    body
    |> MDEx.to_html!(@mdex_opts)
    |> highlight_mentions(known(Keyword.get(opts, :mentions, [])))
    |> restrict_images()
    |> open_links_in_new_tab()
    |> link_channels(Keyword.get(opts, :channels, %{}))
  end

  def to_html(_, _opts), do: ""

  @doc """
  Markdown as one line of plain text, for previews (a quoted parent, a thread
  row, a notification): code fences, emphasis, links, images, headings,
  quotes, list markers and task boxes are stripped and whitespace collapsed.
  Inline code keeps its text without the backticks. Works on fragments too
  (a search snippet cut mid-sentence): unmatched markers are dropped.
  """
  @spec plain(term) :: String.t()
  def plain(text) when is_binary(text) do
    text |> preview_segments() |> Enum.map_join(&elem(&1, 1)) |> collapse()
  end

  def plain(_text), do: ""

  @doc """
  A one-line preview as safe HTML: `plain/1`'s stripping, everything escaped,
  inline code as `<code>`, and text between the `{open, close}` match markers
  (`Canopy.Search.marks/0`) as `<mark>`. Markers never pair across a code
  boundary, so the markup is always balanced. `markdown: false` keeps the
  text as it is (a command's output, a source file), only collapsing
  whitespace.
  """
  @spec preview_html(term, {String.t(), String.t()}, keyword) :: Phoenix.HTML.safe()
  def preview_html(text, marks, opts \\ [])

  def preview_html(text, {open, close}, opts) when is_binary(text) do
    pair = Regex.compile!(Regex.escape(open) <> "(.*?)" <> Regex.escape(close), "su")
    strip = Regex.compile!(Regex.escape(open) <> "|" <> Regex.escape(close), "u")

    if(Keyword.get(opts, :markdown, true), do: preview_segments(text), else: [{:text, text}])
    |> Enum.map(fn {kind, part} -> {kind, collapse_inner(part)} end)
    |> trim_ends()
    |> Enum.map_join(fn {kind, part} ->
      html =
        part
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()
        |> then(&Regex.replace(pair, &1, "<mark>\\1</mark>"))
        |> then(&Regex.replace(strip, &1, ""))

      if kind == :code, do: "<code>" <> html <> "</code>", else: html
    end)
    |> Phoenix.HTML.raw()
  end

  def preview_html(_text, _marks, _opts), do: Phoenix.HTML.raw("")

  # `[{:text | :code, string}]`, Markdown syntax removed, whitespace not yet collapsed.
  defp preview_segments(text) do
    text
    # fences and horizontal rules, then line-start markers: headings, quotes,
    # list bullets and numbers, and a task box after them
    |> String.replace(~r/^[ \t]{0,3}(```|~~~)[^\n]*$/m, " ")
    |> String.replace(~r/^[ \t]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$/m, " ")
    |> String.replace(
      ~r/^[ \t]{0,3}(?:>[ \t]?)*(?:\#{1,6}[ \t]+|[-*+][ \t]+|\d+[.)][ \t]+)?(?:\[[ xX]\][ \t]+)?/m,
      ""
    )
    # images keep their alt text, links their label, autolinks their address
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/<((?:https?|mailto):[^>\s]+)>/, "\\1")
    |> then(&Regex.split(~r/(`+)([^`]+?)\1/, &1, include_captures: true))
    |> Enum.flat_map(fn part ->
      case Regex.run(~r/\A(`+)([^`]+?)\1\z/, part) do
        [_, _, code] -> [{:code, String.trim(code)}]
        nil -> [{:text, strip_inline(part)}]
      end
    end)
    |> Enum.reject(fn {_kind, part} -> part == "" end)
  end

  defp strip_inline(text) do
    text
    |> String.replace(~r/(\*\*|__|~~|`)/, "")
    |> String.replace(~r/(?<![\w*])\*(?![\s*])([^*\n]+?)(?<!\s)\*(?![\w*])/u, "\\1")
    |> String.replace(~r/(?<![\w_])_(?![\s_])([^_\n]+?)(?<!\s)_(?![\w_])/u, "\\1")
  end

  defp collapse(text), do: text |> collapse_inner() |> String.trim()

  defp collapse_inner(text), do: String.replace(text, ~r/\s+/u, " ")

  defp trim_ends([]), do: []

  defp trim_ends(segments) do
    {first_kind, first} = hd(segments)
    segments = [{first_kind, String.trim_leading(first)} | tl(segments)]
    {last_kind, last} = List.last(segments)
    List.replace_at(segments, -1, {last_kind, String.trim_trailing(last)})
  end

  @doc """
  Splits plain text into `{:mention, "@name"}` and `{:plain, text}` parts; only
  the `names` given (as for `to_html/2`'s `:mentions`) count as mentions.
  """
  @spec mention_parts(String.t(), Enumerable.t()) :: [{:mention | :plain, String.t()}]
  def mention_parts(text, names) when is_binary(text) do
    known = known(names)

    @mention_regex
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      if known?(part, known), do: {:mention, part}, else: {:plain, part}
    end)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      [{:plain, _} | _] = plains -> [{:plain, Enum.map_join(plains, &elem(&1, 1))}]
      mentions -> mentions
    end)
  end

  defp known(names), do: MapSet.new(names)

  defp known?("@" <> name, known), do: MapSet.member?(known, String.downcase(name))
  defp known?(_part, _known), do: false

  @doc false
  def mention_class, do: "rounded bg-secondary/10 px-1 font-medium text-secondary"

  # Walk the rendered HTML token by token; text outside <code> gets its
  # mentions wrapped. Rendered text is already entity-escaped, so the span can
  # be spliced in as-is.
  defp highlight_mentions(html, known) do
    if MapSet.size(known) == 0, do: html, else: wrap_outside_code(html, known)
  end

  defp wrap_outside_code(html, known) do
    {out, _in_code} =
      @tag_regex
      |> Regex.split(html, include_captures: true)
      |> Enum.reduce({[], 0}, fn
        "<code" <> _ = tag, {acc, depth} -> {[tag | acc], depth + 1}
        "</code" <> _ = tag, {acc, depth} -> {[tag | acc], max(depth - 1, 0)}
        "<" <> _ = tag, {acc, depth} -> {[tag | acc], depth}
        text, {acc, 0} -> {[wrap_mentions(text, known) | acc], 0}
        text, {acc, depth} -> {[text | acc], depth}
      end)

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp wrap_mentions(text, known) do
    Regex.replace(@mention_regex, text, fn mention ->
      if known?(mention, known),
        do: ~s(<span class="#{mention_class()}">#{mention}</span>),
        else: mention
    end)
  end

  @img_regex ~r/<img\s+([^>]*?)\s*\/?>/
  @local_src ~r/\bsrc="\/files\/[^"]*"/

  # Local images get lazy loading and a class the timeline styles; remote ones
  # are downgraded to a link with the alt text (or the URL) as its label.
  defp restrict_images(html) do
    Regex.replace(@img_regex, html, fn whole, attrs ->
      if Regex.match?(@local_src, attrs) do
        ~s(<img loading="lazy" class="message-image" #{attrs} />)
      else
        src = attr(attrs, "src")
        alt = attr(attrs, "alt")
        label = if alt in [nil, ""], do: src || whole, else: alt
        if src, do: ~s(<a href="#{src}">#{label}</a>), else: label
      end
    end)
  end

  defp attr(attrs, name) do
    case Regex.run(~r/\b#{name}="([^"]*)"/, attrs) do
      [_, value] -> value
      nil -> nil
    end
  end

  # `&` keeps entities like `&#39;` out; `&amp;` is a typed `&`, which the
  # composer's highlight (and the raw-text match) also leaves alone.
  @channel_regex ~r/(?<![\w#&\/])(?<!&amp;)#([a-z0-9][a-z0-9_-]*)/i

  @doc false
  # The composer highlight (assets/js/composer_tokens.js) mirrors this.
  def channel_regex, do: @channel_regex

  @doc false
  def channel_class, do: "rounded bg-primary/10 px-1 font-medium text-primary no-underline"

  # `#name` outside code and outside other links becomes a live link when the
  # name is a known channel.
  defp link_channels(html, channels) when map_size(channels) == 0, do: html

  defp link_channels(html, channels) do
    {out, _depth} =
      @tag_regex
      |> Regex.split(html, include_captures: true)
      |> Enum.reduce({[], 0}, fn
        "<code" <> _ = tag, {acc, depth} -> {[tag | acc], depth + 1}
        "</code" <> _ = tag, {acc, depth} -> {[tag | acc], max(depth - 1, 0)}
        "<a " <> _ = tag, {acc, depth} -> {[tag | acc], depth + 1}
        "</a" <> _ = tag, {acc, depth} -> {[tag | acc], max(depth - 1, 0)}
        "<" <> _ = tag, {acc, depth} -> {[tag | acc], depth}
        text, {acc, 0} -> {[link_channel_refs(text, channels) | acc], 0}
        text, {acc, depth} -> {[text | acc], depth}
      end)

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp link_channel_refs(text, channels) do
    Regex.replace(@channel_regex, text, fn whole, name ->
      case Map.get(channels, String.downcase(name)) do
        nil ->
          whole

        id ->
          ~s(<a href="/channels/#{id}" data-phx-link="redirect" data-phx-link-state="push" class="#{channel_class()}">##{name}</a>)
      end
    end)
  end

  defp open_links_in_new_tab(html),
    do: String.replace(html, "<a href=", ~s(<a target="_blank" rel="noopener noreferrer" href=))
end
