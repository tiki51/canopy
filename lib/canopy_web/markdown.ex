defmodule CanopyWeb.Markdown do
  @moduledoc """
  Renders message bodies written in GitHub-flavoured Markdown to safe HTML.

  Raw HTML in the source is escaped rather than passed through, dangerous link
  schemes are dropped by the renderer, and single newlines become line breaks
  so chat-style messages keep their shape. `@mentions` outside code are
  wrapped in a highlight span after rendering.

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

  Options: `channels: %{"name" => channel_id}` turns `#name` references outside
  code and links into in-app links to those channels; unknown names are left
  as text.
  """
  @spec to_html(term, keyword) :: String.t()
  def to_html(body, opts \\ [])

  def to_html(body, opts) when is_binary(body) do
    body
    |> MDEx.to_html!(@mdex_opts)
    |> highlight_mentions()
    |> restrict_images()
    |> open_links_in_new_tab()
    |> link_channels(Keyword.get(opts, :channels, %{}))
  end

  def to_html(_, _opts), do: ""

  @doc "Splits plain text into `{:mention, \"@name\"}` and `{:plain, text}` parts."
  @spec mention_parts(String.t()) :: [{:mention | :plain, String.t()}]
  def mention_parts(text) when is_binary(text) do
    @mention_regex
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn
      "@" <> _ = mention -> {:mention, mention}
      plain -> {:plain, plain}
    end)
  end

  @doc false
  def mention_class, do: "rounded bg-secondary/10 px-1 font-medium text-secondary"

  # Walk the rendered HTML token by token; text outside <code> gets its
  # mentions wrapped. Rendered text is already entity-escaped, so the span can
  # be spliced in as-is.
  defp highlight_mentions(html) do
    {out, _in_code} =
      @tag_regex
      |> Regex.split(html, include_captures: true)
      |> Enum.reduce({[], 0}, fn
        "<code" <> _ = tag, {acc, depth} -> {[tag | acc], depth + 1}
        "</code" <> _ = tag, {acc, depth} -> {[tag | acc], max(depth - 1, 0)}
        "<" <> _ = tag, {acc, depth} -> {[tag | acc], depth}
        text, {acc, 0} -> {[wrap_mentions(text) | acc], 0}
        text, {acc, depth} -> {[text | acc], depth}
      end)

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp wrap_mentions(text) do
    Regex.replace(@mention_regex, text, ~s(<span class="#{mention_class()}">\\1</span>))
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

  @channel_regex ~r/(?<![\w#&\/])#([a-z0-9][a-z0-9_-]*)/i

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
