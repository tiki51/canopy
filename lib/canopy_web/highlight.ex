defmodule CanopyWeb.Highlight do
  @moduledoc """
  Syntax highlighting for the file viewer and for code fences in documents,
  with Lumis (Tree-sitter). Output is one `<span class="l-line">` per line
  inside `<code>`, tokens as `l-*` classes; `app.css` numbers the lines with
  a CSS counter and colours the tokens per theme (`.doc-code`).

  Only the languages in `mix.exs` (`lumis_wasm_*`) can be coloured: Elixir,
  Python, JavaScript and TypeScript, JSON, YAML, HTML, CSS, Bash, SQL,
  Markdown, Rust, Go and Ruby. Anything else, or a highlighter failure,
  comes back as escaped plain lines.
  """

  # extension (or whole file name) => {Lumis language, label}; a nil language
  # is named but not coloured (its grammar isn't bundled)
  @languages %{
    "ex" => {"elixir", "Elixir"},
    "exs" => {"elixir", "Elixir"},
    "heex" => {nil, "HEEx"},
    "eex" => {nil, "EEx"},
    "py" => {"python", "Python"},
    "js" => {"javascript", "JavaScript"},
    "mjs" => {"javascript", "JavaScript"},
    "cjs" => {"javascript", "JavaScript"},
    "jsx" => {"javascript", "JavaScript"},
    "ts" => {"typescript", "TypeScript"},
    "tsx" => {"tsx", "TypeScript"},
    "rb" => {"ruby", "Ruby"},
    "go" => {"go", "Go"},
    "rs" => {"rust", "Rust"},
    "java" => {nil, "Java"},
    "kt" => {nil, "Kotlin"},
    "swift" => {nil, "Swift"},
    "c" => {nil, "C"},
    "h" => {nil, "C"},
    "cpp" => {nil, "C++"},
    "hpp" => {nil, "C++"},
    "cc" => {nil, "C++"},
    "cs" => {nil, "C#"},
    "php" => {nil, "PHP"},
    "sh" => {"bash", "Shell"},
    "bash" => {"bash", "Shell"},
    "zsh" => {"bash", "Shell"},
    "sql" => {"sql", "SQL"},
    "html" => {"html", "HTML"},
    "htm" => {"html", "HTML"},
    "css" => {"css", "CSS"},
    "scss" => {nil, "SCSS"},
    "json" => {"json", "JSON"},
    "yaml" => {"yaml", "YAML"},
    "yml" => {"yaml", "YAML"},
    "toml" => {nil, "TOML"},
    "xml" => {nil, "XML"},
    "svg" => {nil, "SVG"},
    "md" => {"markdown", "Markdown"},
    "markdown" => {"markdown", "Markdown"},
    "mdx" => {"markdown", "Markdown"},
    "diff" => {nil, "Diff"},
    "patch" => {nil, "Diff"}
  }

  @filenames %{
    "dockerfile" => {nil, "Dockerfile"},
    "makefile" => {nil, "Makefile"}
  }

  # code fence info strings that aren't an extension
  @fence_aliases %{
    "elixir" => "ex",
    "python" => "py",
    "javascript" => "js",
    "typescript" => "ts",
    "ruby" => "rb",
    "rust" => "rs",
    "kotlin" => "kt",
    "csharp" => "cs",
    "shell" => "sh",
    "console" => "sh",
    "dockerfile" => "dockerfile",
    "makefile" => "makefile",
    "make" => "makefile"
  }

  @doc """
  The language of a file, by its name: `{lumis_language, label}`, or nil for
  plain text.
  """
  @spec language(String.t()) :: {String.t() | nil, String.t()} | nil
  def language(filename) when is_binary(filename) do
    base = filename |> Path.basename() |> String.downcase()
    ext = base |> Path.extname() |> String.trim_leading(".")
    Map.get(@filenames, base) || Map.get(@languages, ext)
  end

  @doc "The language of a code fence's info string (`python`, `py`, `ex`…), or nil."
  @spec fence_language(String.t() | nil) :: String.t() | nil
  def fence_language(nil), do: nil

  def fence_language(info) do
    key = info |> String.downcase() |> String.trim()
    key = Map.get(@fence_aliases, key, key)

    case Map.get(@filenames, key) || Map.get(@languages, key) do
      {lang, _label} -> lang
      nil -> nil
    end
  end

  # Past these, colouring costs too much (time in the LiveView, HTML on the
  # wire: 1 MB of minified JSON is ~15 MB of spans), so the lines stay plain.
  @max_bytes 262_144
  @max_line_bytes 5_000

  @doc "The most bytes a text can have and still be coloured."
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  @doc "Whether `text` is small enough to colour (see `code/2`)."
  @spec colourable?(String.t()) :: boolean
  def colourable?(text) when is_binary(text) do
    byte_size(text) <= @max_bytes and
      text |> :binary.split("\n", [:global]) |> Enum.all?(&(byte_size(&1) <= @max_line_bytes))
  end

  @doc """
  `text` as highlighted HTML: `<code class="language-…">` holding one
  `<span class="l-line">` per line. `lang` nil means plain text, and so does
  a text over 256 KB or with a line over 5,000 bytes.
  """
  @spec code(String.t(), String.t() | nil) :: String.t()
  def code("", _lang), do: ~s(<code class="language-plaintext"></code>)

  def code(text, lang) when is_binary(text) do
    # a final newline ends the last line; it isn't one of its own
    text = text |> String.replace("\r\n", "\n") |> String.replace_suffix("\n", "")

    with true <- lang != nil and colourable?(text),
         {:ok, html} <- Lumis.highlight(text, formatter: {:html_linked, language: lang}) do
      unwrap(html)
    else
      _ -> plain(text)
    end
  end

  # Lumis wraps the lines in <pre class="lumis"><code …>; the viewer brings its
  # own <pre>. The newlines between line spans go too: the lines are blocks.
  defp unwrap(html) do
    html
    |> String.replace(~r/\A<pre[^>]*>/, "")
    |> String.replace(~r/<\/pre>\s*\z/, "")
    |> String.replace("</span>\n<span class=\"l-line\"", "</span><span class=\"l-line\"")
  end

  defp plain(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_join(fn {line, n} ->
        ~s(<span class="l-line" data-line="#{n}">) <>
          (line |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()) <> "</span>"
      end)

    ~s(<code class="language-plaintext">) <> lines <> "</code>"
  end
end
