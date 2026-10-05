defmodule Canopy.Playbooks.Writer do
  @moduledoc """
  The playbook builder's side of the text: `draft/1` turns a parsed
  `Canopy.Playbooks.Definition` into a draft the builder edits, and
  `to_text/1` writes a draft back as the same Markdown with YAML
  frontmatter. `Definition.parse/1` stays the source of truth: the builder
  parses what `to_text/1` writes, so a draft that would not parse is never
  saved.

  A draft is a map:

    * `:title` — the body's `# Heading` (the human name)
    * `:name`, `:description`, `:team`, `:coordinator`, `:channel`,
      `:stall_after`, `:inputs` — as on the definition
    * `:roles` — `[%{key: role, agent: name | nil}]`, in order of first use;
      a role with no agent is kept for the builder but not written
    * `:guidance` — the ground rules, between the heading and the first step
      section
    * `:steps` — `[%{id, title, owner, on_reject, approval, optional,
      instructions, done_when}]`; `instructions` is the step's `## <id>`
      section without its closing `Done when:` paragraph
    * `:notes` — `[{heading, text}]`, later sections that match no step,
      kept verbatim at the end of the body

  Frontmatter keys come out in a fixed order, and defaults (`channel:
  current`, a 30 minute `stall_after`) are left out. YAML comments are not
  kept. Pure.
  """

  alias Canopy.Frontmatter
  alias Canopy.Playbooks.Definition

  @done_when ~r/\Adone when:/i

  @doc "The draft for a parsed definition."
  def draft(%Definition{} = definition) do
    {title, guidance, sections} =
      split_body(definition.body, MapSet.new(definition.steps, & &1.id))

    by_heading =
      Enum.reduce(Enum.reverse(sections), %{}, fn {h, t}, acc -> Map.put(acc, h, t) end)

    step_ids = MapSet.new(definition.steps, & &1.id)

    %{
      title: title || humanize(definition.name),
      name: definition.name,
      description: definition.description,
      team: definition.team,
      coordinator: definition.coordinator,
      channel: definition.channel,
      stall_after: definition.stall_after,
      inputs: definition.inputs,
      roles: roles(definition),
      guidance: guidance,
      steps:
        Enum.map(definition.steps, fn step ->
          {instructions, done_when} = split_done_when(Map.get(by_heading, step.id, ""))

          %{
            id: step.id,
            title: step.title,
            owner: step.owner,
            on_reject: step.on_reject,
            approval: step.approval,
            optional: step.optional,
            instructions: instructions,
            done_when: done_when
          }
        end),
      notes: notes(sections, step_ids)
    }
  end

  @doc "A blank draft: a name, no steps, the defaults."
  def blank do
    %{
      title: "",
      name: "",
      description: "",
      team: nil,
      coordinator: nil,
      channel: "current",
      stall_after: Definition.default_stall_minutes(),
      inputs: nil,
      roles: [],
      guidance: "",
      steps: [],
      notes: []
    }
  end

  @doc "The draft as a playbook's text."
  def to_text(draft) do
    "---\n" <> frontmatter(draft) <> "---\n\n" <> body(draft) <> "\n"
  end

  @doc "`bug-fix` → `Bug fix`."
  def humanize(nil), do: ""

  def humanize(name) do
    case name |> String.replace("-", " ") |> String.trim() do
      "" -> ""
      text -> String.capitalize(String.first(text)) <> String.slice(text, 1..-1//1)
    end
  end

  @doc "A kebab-case slug of `text`, at most `max` characters: `Bug fix!` → `bug-fix`."
  def slug(text, max \\ 40) do
    text
    |> to_string()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, max)
    |> String.trim("-")
  end

  # -- Frontmatter ----------------------------------------------------------------

  defp frontmatter(draft) do
    [
      line("name", draft.name),
      line("description", draft.description),
      line("team", draft.team),
      roles_block(draft.roles),
      line("coordinator", draft.coordinator),
      if(draft.channel == "new", do: "channel: new\n"),
      stall_line(draft.stall_after),
      line("inputs", draft.inputs),
      steps_block(draft.steps)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp line(_key, value) when value in [nil, ""], do: nil
  defp line(key, value), do: key <> ": " <> Frontmatter.scalar(String.trim(value)) <> "\n"

  defp roles_block(roles) do
    case Enum.filter(roles, &present?(&1.agent)) do
      [] ->
        nil

      roles ->
        "roles:\n" <>
          Enum.map_join(roles, "", fn %{key: key, agent: agent} ->
            "  #{Frontmatter.scalar(key)}: #{Frontmatter.scalar(agent)}\n"
          end)
    end
  end

  defp stall_line(minutes) do
    cond do
      minutes == Definition.default_stall_minutes() -> nil
      is_nil(minutes) -> "stall_after: off\n"
      rem(minutes, 60) == 0 -> "stall_after: #{div(minutes, 60)}h\n"
      true -> "stall_after: #{minutes}m\n"
    end
  end

  defp steps_block([]), do: "steps:\n"

  defp steps_block(steps) do
    "steps:\n" <>
      Enum.map_join(steps, "", fn step ->
        [
          "  - id: #{Frontmatter.scalar(step.id || "")}\n",
          present?(step.title) && "    title: #{Frontmatter.scalar(String.trim(step.title))}\n",
          owner_line(step.owner),
          present?(step.on_reject) && "    on_reject: #{Frontmatter.scalar(step.on_reject)}\n",
          step.approval && "    approval: user\n",
          step.optional && "    optional: true\n"
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join()
      end)
  end

  defp owner_line([]), do: nil
  defp owner_line([owner]), do: "    owner: #{Frontmatter.scalar(owner)}\n"
  defp owner_line(owners), do: "    owner: [#{Enum.map_join(owners, ", ", &flow_scalar/1)}]\n"

  # inside `[ ]` a comma or bracket ends the item, so anything but a plain
  # name is quoted
  defp flow_scalar(value) do
    if Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/, value) and
         String.downcase(value) not in ~w(true false yes no on off y n null),
       do: value,
       else: Jason.encode!(value)
  end

  # -- Body -------------------------------------------------------------------------

  defp body(draft) do
    sections =
      Enum.map(draft.steps, fn step ->
        text =
          [demote(trim(step.instructions), fn _ -> true end), done_paragraph(step.done_when)]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n\n")

        section(step.id, text)
      end)

    notes = Enum.map(draft.notes, fn {heading, text} -> section(heading, trim(text)) end)

    title = String.trim(to_string(draft.title))
    title = if title == "", do: humanize(draft.name), else: title

    step_ids = MapSet.new(draft.steps, & &1.id)
    guidance = demote(trim(draft.guidance), &MapSet.member?(step_ids, &1))

    ["# " <> title, guidance | sections ++ notes]
    |> Enum.reject(&(&1 in ["", "# "]))
    |> Enum.join("\n\n")
  end

  # a step with nothing to say gets no section: a run then reads "no
  # instructions" rather than an empty one
  defp section(_heading, ""), do: ""
  defp section(heading, text), do: "## " <> to_string(heading) <> "\n\n" <> text

  # A `## ` line typed into a step would start a section of its own when the
  # file is read back, and in the ground rules one named like a step would start
  # that step early; such a line is written as `### `. Fenced code stays as typed.
  defp demote(text, breaks?) do
    text
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, fenced ->
      cond do
        Regex.match?(~r/\A\s*(```|~~~)/, line) -> {line, not fenced}
        not fenced and breaks_section?(line, breaks?) -> {"#" <> line, fenced}
        true -> {line, fenced}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp breaks_section?(line, breaks?) do
    case heading(line) do
      nil -> false
      h -> breaks?.(h)
    end
  end

  defp done_paragraph(text) do
    case trim(text) do
      "" -> ""
      text -> "Done when: " <> text
    end
  end

  # -- Reading the body ---------------------------------------------------------------

  # {title, guidance, [{heading, text}]}: the leading `# Heading`, the text
  # up to the first step section (the same cut as `Definition.guidance/1`),
  # then every `##` section from there on.
  defp split_body(body, step_ids) do
    lines = String.split(body || "", "\n")

    {head, rest} =
      Enum.split_while(lines, fn line ->
        case heading(line) do
          nil -> true
          h -> not MapSet.member?(step_ids, h)
        end
      end)

    {title, guidance} = split_title(head)
    {title, guidance, sections(rest)}
  end

  defp split_title(lines) do
    case Enum.drop_while(lines, &(String.trim(&1) == "")) do
      [first | rest] ->
        case Regex.run(~r/\A#[ \t]+(.+?)[ \t]*#*[ \t]*\z/, first) do
          [_, title] -> {String.trim(title), lines_text(rest)}
          nil -> {nil, lines_text(lines)}
        end

      [] ->
        {nil, ""}
    end
  end

  defp sections(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case {heading(line), acc} do
        {nil, []} -> []
        {nil, [{h, ls} | done]} -> [{h, [line | ls]} | done]
        {h, acc} -> [{h, []} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {h, ls} -> {h, ls |> Enum.reverse() |> lines_text()} end)
  end

  # "## sign-off" -> "sign-off", as `Definition` reads step sections
  defp heading(line) do
    case Regex.run(~r/\A##[ \t]+(.+?)[ \t]*#*[ \t]*\z/, line) do
      [_, text] -> String.trim(text)
      nil -> nil
    end
  end

  defp notes(sections, step_ids) do
    {notes, _seen} =
      Enum.reduce(sections, {[], MapSet.new()}, fn {h, text}, {notes, seen} ->
        if MapSet.member?(step_ids, h) and not MapSet.member?(seen, h),
          do: {notes, MapSet.put(seen, h)},
          else: {[{h, text} | notes], seen}
      end)

    Enum.reverse(notes)
  end

  # The section's last paragraph, when it starts with "Done when:", is the
  # step's "Done when"; it is one line in the builder. A wrapped sentence
  # joins up the same as Markdown would render it; a paragraph with a list,
  # quote, code or hard break in it stays in the instructions as written.
  defp split_done_when(text) do
    paragraphs = String.split(text, ~r/\n[ \t]*\n/)
    last = paragraphs |> List.last() |> to_string() |> String.trim()

    if Regex.match?(@done_when, last) and one_line?(last) do
      done =
        last
        |> String.replace(@done_when, "")
        |> String.replace(~r/\s*\n\s*/, " ")
        |> String.trim()

      {paragraphs |> Enum.drop(-1) |> Enum.join("\n\n") |> String.trim(), done}
    else
      {String.trim(text), ""}
    end
  end

  @block_line ~r/\A(\s{4}|\s*([-*+>#|]|\d+[.)]|```|~~~))/

  defp one_line?(paragraph) do
    [_first | rest] = String.split(paragraph, "\n")

    not Enum.any?(rest, &Regex.match?(@block_line, &1)) and
      not Regex.match?(~r/(  |\\)\n/, paragraph)
  end

  defp roles(%Definition{roles: roles} = definition) do
    used = Definition.owner_roles(definition)
    rest = roles |> Map.keys() |> Enum.reject(&(&1 in used)) |> Enum.sort()

    Enum.map(used ++ rest, fn key -> %{key: key, agent: Map.get(roles, key)} end)
  end

  defp lines_text(lines), do: lines |> Enum.join("\n") |> String.trim()

  defp trim(nil), do: ""
  defp trim(text), do: String.trim(text)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
