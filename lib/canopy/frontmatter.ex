defmodule Canopy.Frontmatter do
  @moduledoc """
  Markdown with YAML frontmatter, the shape of playbooks and agent templates:
  the text opens with a `---` line, the YAML runs to the next line that is
  exactly `---`, and the rest is the body (a `---` inside the body is fine).

  Reading is guarded, because the text comes from users, agents and imported
  files: callers cap the size before anything is parsed (`check_size/3`),
  YAML anchors and aliases are refused before the parser runs, and the parser
  (`yaml_elixir`) creates no atoms. Every failure is a human-readable line.

  `encode/1` writes frontmatter: `yaml_elixir` only parses, so the emitter is
  ours, and deliberately small (text, integers, booleans, lists of text, and
  lists of flat maps).

  Pure.
  """

  @doc """
  Splits a text into `{:ok, yaml, body}`. An optional BOM and CRLF line ends
  are accepted. `what` names the text in the error ("the playbook").
  """
  def split(text, what \\ "the text") when is_binary(text) do
    text = text |> String.replace("\r\n", "\n") |> String.trim_leading("﻿")

    case Regex.run(~r/\A\s*---[ \t]*\n(.*?)\n---[ \t]*(?:\n(.*))?\z/s, text) do
      [_, yaml] -> {:ok, yaml, ""}
      [_, yaml, body] -> {:ok, yaml, body}
      nil -> {:error, ["#{what} must start with YAML frontmatter between --- lines"]}
    end
  end

  @doc "`:ok`, or a reason when `text` is over `max` bytes."
  def check_size(text, max, what) do
    if byte_size(text) > max,
      do: {:error, ["#{what} is too long (at most #{max} bytes)"]},
      else: :ok
  end

  # YAML anchors and aliases (`&name`, `*name`) let a few lines expand into a
  # huge document; nothing Canopy reads needs them, so they are refused before
  # the parser runs. Both can only start a value or an item, which is where
  # this looks; inside quotes they are plain text.
  @anchor_or_alias ~r/(?:^|:[ \t]+|-[ \t]+|\?[ \t]+|[\[{,][ \t]*)[&*][^\s\[\]{},]/m

  @doc "`:ok`, or a reason when the YAML uses anchors or aliases. `what` names the document."
  def check_no_anchors(yaml, what \\ "the frontmatter") do
    if Regex.match?(@anchor_or_alias, yaml),
      do: {:error, ["YAML anchors and aliases (&name, *name) are not allowed in #{what}"]},
      else: :ok
  end

  @doc """
  Parses the YAML into a map with text keys, or `{:error, lines}`. Call it
  only after `check_size/3` and `check_no_anchors/2`.
  """
  def parse(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = data} ->
        if Enum.all?(Map.keys(data), &is_binary/1),
          do: {:ok, data},
          else: {:error, ["field names in the frontmatter must be plain text"]}

      {:ok, _other} ->
        {:error, ["the frontmatter must be a set of key: value fields"]}

      {:error, %{message: message}} ->
        {:error, ["invalid YAML: " <> one_line(message)]}

      {:error, other} ->
        {:error, ["invalid YAML: " <> one_line(inspect(other))]}
    end
  rescue
    e -> {:error, ["invalid YAML: " <> one_line(Exception.message(e))]}
  end

  @doc """
  The guarded read in one call: the whole text at most `max_bytes`, the
  frontmatter at most `max_header_bytes`, no anchors, a map of fields.
  `{:ok, data, body}` or `{:error, lines}`. `what` names the text.
  """
  def read(text, what, max_bytes, max_header_bytes) when is_binary(text) do
    with :ok <- check_size(text, max_bytes, what),
         {:ok, yaml, body} <- split(text, what),
         :ok <- check_size(yaml, max_header_bytes, "the frontmatter"),
         :ok <- check_no_anchors(yaml, what),
         {:ok, data} <- parse(yaml) do
      {:ok, data, body}
    end
  end

  @doc "The first line of a message, trimmed: parser errors can run long."
  def one_line(text), do: text |> String.split("\n") |> hd() |> String.trim()

  # -- Writing ------------------------------------------------------------------

  @doc """
  Writes `fields` (an ordered list of `{key, value}`) as YAML frontmatter,
  without the `---` lines. Nil values are left out. A value is text, an
  integer, a boolean, a list of text, or a list of flat maps of those (as
  ordered `{key, value}` lists or maps).
  """
  def encode(fields) when is_list(fields) do
    fields
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Enum.map_join("", fn {key, value} -> entry(to_string(key), value) end)
  end

  @doc "A whole document: the frontmatter between `---` lines, then the body."
  def document(fields, body) do
    body = if is_binary(body), do: String.trim(body), else: ""
    head = "---\n" <> encode(fields) <> "---\n"
    if body == "", do: head, else: head <> "\n" <> body <> "\n"
  end

  defp entry(key, list) when is_list(list) do
    key <> ":\n" <> Enum.map_join(list, "", &item/1)
  end

  defp entry(key, value), do: key <> ": " <> scalar(value) <> "\n"

  defp item(fields) when is_map(fields) or (is_list(fields) and fields != []) do
    [{first_key, first} | rest] =
      fields |> Enum.to_list() |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    "  - #{first_key}: #{scalar(first)}\n" <>
      Enum.map_join(rest, "", fn {k, v} -> "    #{k}: #{scalar(v)}\n" end)
  end

  defp item(value), do: "  - " <> scalar(value) <> "\n"

  defp scalar(value) when is_integer(value) or is_boolean(value), do: to_string(value)
  defp scalar(value) when is_atom(value), do: scalar(Atom.to_string(value))

  # Plain when it cannot be read as anything but this text; otherwise a JSON
  # string, which is a valid YAML double-quoted scalar.
  defp scalar(value) when is_binary(value) do
    if plain?(value), do: value, else: Jason.encode!(value)
  end

  @keywords ~w(true false yes no on off y n null ~)

  defp plain?(value) do
    value != "" and value == String.trim(value) and String.printable?(value) and
      not String.contains?(value, [":", "#", "\n", "\r", "\t", "\\"]) and
      Regex.match?(~r/\A[\p{L}_\/(]/u, value) and
      String.downcase(value) not in @keywords
  end
end
