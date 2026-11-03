defmodule Canopy.Playbooks.Sharing.Text do
  @moduledoc """
  Pure text helpers for shared playbooks: the content hash that says whether
  two copies are the same playbook, and the `name:`/`version:` frontmatter
  lines a shared file carries.
  """

  @name_line ~r/^name:[^\n]*$/m

  @doc """
  The sha256 (hex) of the normalised text: CRLF as LF, the top-level `name:`
  and `version:` lines dropped, trailing spaces trimmed per line, trailing
  blank lines trimmed. Dropping `name` lets a renamed copy (`-2`) still match
  its source; dropping `version` lets the number move without changing state.
  """
  def content_hash(text) when is_binary(text) do
    normalised =
      text
      |> String.replace("\r\n", "\n")
      |> map_frontmatter(fn header ->
        header
        |> String.split("\n")
        |> Enum.reject(&(String.starts_with?(&1, "name:") or String.starts_with?(&1, "version:")))
        |> Enum.join("\n")
      end)
      |> String.split("\n")
      |> Enum.map_join("\n", &String.trim_trailing/1)
      |> String.trim_trailing()

    :crypto.hash(:sha256, normalised) |> Base.encode16(case: :lower)
  end

  def content_hash(nil), do: nil

  @doc "Removes a top-level `version:` line from the frontmatter only."
  def strip_version(text) when is_binary(text) do
    map_frontmatter(text, fn header ->
      header
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "version:"))
      |> Enum.join("\n")
    end)
  end

  @doc "Writes `version: n` on the line after `name:`, replacing any existing one."
  def put_version(text, n) when is_binary(text) and is_integer(n) do
    text
    |> strip_version()
    |> map_frontmatter(fn header ->
      if Regex.match?(@name_line, header),
        do: Regex.replace(@name_line, header, "\\0\nversion: #{n}", global: false),
        else: "version: #{n}\n" <> header
    end)
  end

  @doc "Replaces the top-level `name:` line."
  def put_name(text, name) when is_binary(text) and is_binary(name) do
    map_frontmatter(text, &Regex.replace(@name_line, &1, "name: " <> name, global: false))
  end

  @doc ~S|The file a playbook is shared as: `file_path("playbooks", "bug-fix")` is `"playbooks/bug-fix.md"`.|
  def file_path(folder, name) when folder in [nil, ""], do: name <> ".md"
  def file_path(folder, name), do: folder <> "/" <> name <> ".md"

  # Applies `fun` to the frontmatter between the opening and closing `---`
  # lines, leaving the rest alone; text with no frontmatter is unchanged.
  defp map_frontmatter(text, fun) do
    case Regex.run(~r/\A(---[ \t]*\r?\n)(.*?)(\r?\n---[ \t]*(?:\r?\n|\z))/s, text, return: :index) do
      [_, {o_at, o_len}, {h_at, h_len}, {c_at, _}] ->
        opening = binary_part(text, o_at, o_len)
        header = binary_part(text, h_at, h_len)
        rest = binary_part(text, c_at, byte_size(text) - c_at)
        opening <> fun.(header) <> rest

      nil ->
        text
    end
  end
end
