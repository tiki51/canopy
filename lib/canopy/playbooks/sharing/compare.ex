defmodule Canopy.Playbooks.Sharing.Compare do
  @moduledoc """
  Pure: what differs between your copy of a playbook and GitHub's, for the
  Compare dialog. Steps are aligned by id; with a base (the text at the last
  sync) each difference says who made it: `:remote` where yours still equals
  the base, `:local` where GitHub's does, `:both` otherwise, and nil with no
  base (a name clash). Rows and `changes` are relative to importing: a step
  only on GitHub is `:added`.
  """

  alias Canopy.Playbooks.Definition
  alias Canopy.Playbooks.Sharing.Text

  @fields [
    {:description, "the description"},
    {:roles, "the roles"},
    {:team, "the team"},
    {:coordinator, "the coordinator"},
    {:inputs, "the inputs"},
    {:stall_after, "the stall time"},
    {:section, "the section"}
  ]
  @short 80
  @context 3

  @doc """
  The comparison parts: `changes`, `rows`, `instructions` and `file_diff`.
  `local` is nil for a file not in the library (only GitHub's side is
  shown). Texts are full files; `version:` lines are ignored except in the
  file diff, which labels each side with its version.
  """
  def compare(local, remote, base, opts \\ []) do
    remote_def = parse!(remote)
    local_version = opts[:local_version]
    remote_version = opts[:remote_version]

    if local == nil do
      %{
        changes: [],
        rows: Enum.map(remote_def.steps, &{nil, &1, :added}),
        instructions: new_instructions(remote_def),
        file_diff: file_diff(nil, remote, nil, remote_version)
      }
    else
      local_def = parse!(local)
      base_def = base && parse(base)

      %{
        changes: changes(local_def, remote_def, base_def),
        rows: rows(local_def, remote_def),
        instructions: instructions(local_def, remote_def),
        file_diff: file_diff(local, remote, local_version, remote_version)
      }
    end
  end

  defp parse(text) do
    case Definition.parse(Text.strip_version(text)) do
      {:ok, definition} -> definition
      {:error, _} -> nil
    end
  end

  defp parse!(text) do
    parse(text) || raise ArgumentError, "the playbook text does not parse"
  end

  # -- Rows ---------------------------------------------------------------------

  defp rows(local, remote) do
    {deleted, inserted} = moved_sets(local, remote)
    moved = MapSet.intersection(deleted, inserted)
    remote_steps = Map.new(remote.steps, &{&1.id, &1})
    local_steps = Map.new(local.steps, &{&1.id, &1})

    local.steps
    |> ids()
    |> List.myers_difference(ids(remote.steps))
    |> Enum.flat_map(fn
      {:eq, ids} ->
        Enum.map(ids, fn id ->
          l = local_steps[id]
          r = remote_steps[id]
          {l, r, if(same_step?(local, remote, id), do: :same, else: :changed)}
        end)

      {:del, ids} ->
        Enum.map(ids, &{local_steps[&1], nil, if(&1 in moved, do: :moved, else: :removed)})

      {:ins, ids} ->
        Enum.map(ids, &{nil, remote_steps[&1], if(&1 in moved, do: :moved, else: :added)})
    end)
  end

  defp moved_sets(local, remote) do
    local.steps
    |> ids()
    |> List.myers_difference(ids(remote.steps))
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn
      {:del, ids}, {d, i} -> {MapSet.union(d, MapSet.new(ids)), i}
      {:ins, ids}, {d, i} -> {d, MapSet.union(i, MapSet.new(ids))}
      _, acc -> acc
    end)
  end

  defp ids(steps), do: Enum.map(steps, & &1.id)

  # Who reordered: compares only the steps all three sides have, so an add or
  # remove on one side doesn't read as that side moving steps too
  defp order_by(_local_ids, _remote_ids, nil), do: nil

  defp order_by(local_ids, remote_ids, base_ids) do
    shared =
      MapSet.new(local_ids)
      |> MapSet.intersection(MapSet.new(remote_ids))
      |> MapSet.intersection(MapSet.new(base_ids))

    keep = fn ids -> Enum.filter(ids, &MapSet.member?(shared, &1)) end
    by(keep.(local_ids), keep.(remote_ids), keep.(base_ids))
  end

  defp same_step?(local, remote, id) do
    Definition.step(local, id) == Definition.step(remote, id) and
      section(local, id) == section(remote, id)
  end

  defp section(definition, id), do: Definition.step_section(definition, id) || ""

  # -- Changes ------------------------------------------------------------------

  defp changes(local, remote, base) do
    step_changes(local, remote, base) ++
      field_changes(local, remote, base) ++
      title_change(local, remote, base) ++ guidance_change(local, remote, base)
  end

  defp step_changes(local, remote, base) do
    {deleted, inserted} = moved_sets(local, remote)
    moved = MapSet.intersection(deleted, inserted)
    local_ids = ids(local.steps)
    remote_ids = ids(remote.steps)
    base_ids = base && ids(base.steps)
    order_by = order_by(local_ids, remote_ids, base_ids)

    added =
      for id <- remote_ids, id not in local_ids do
        step = Definition.step(remote, id)
        in_base? = base_ids && id in base_ids
        by = if base, do: if(in_base?, do: :local, else: :remote)

        text =
          case by do
            :local -> "You removed step #{step.title}; GitHub still has it"
            :remote -> "GitHub adds step #{step.title} (#{owners(step)})#{after_text(remote, id)}"
            nil -> "GitHub's copy has step #{step.title} (#{owners(step)})"
          end

        %{kind: :added, by: by, step: step.title, text: text}
      end

    removed =
      for id <- local_ids, id not in remote_ids do
        step = Definition.step(local, id)
        in_base? = base_ids && id in base_ids
        by = if base, do: if(in_base?, do: :remote, else: :local)

        text =
          case by do
            :remote -> "GitHub removes step #{step.title}"
            :local -> "You added step #{step.title} (#{owners(step)})"
            nil -> "Yours has step #{step.title} (#{owners(step)})"
          end

        %{kind: :removed, by: by, step: step.title, text: text}
      end

    moves =
      for id <- remote_ids, id in moved do
        step = Definition.step(remote, id)
        %{kind: :moved, by: order_by, step: step.title, text: moved_text(order_by, step)}
      end

    common =
      for id <- remote_ids, id in local_ids do
        l = Definition.step(local, id)
        r = Definition.step(remote, id)
        b = base && Definition.step(base, id)
        common_step_changes(id, l, r, b, local, remote, base)
      end
      |> List.flatten()

    added ++ removed ++ moves ++ common
  end

  defp moved_text(by, step) do
    case by do
      :remote -> "GitHub moves step #{step.title}"
      :local -> "You moved step #{step.title}"
      :both -> "Both moved step #{step.title}"
      nil -> "Step #{step.title} is in a different place"
    end
  end

  defp common_step_changes(id, l, r, b, local, remote, base) do
    title =
      if l.title != r.title do
        by = by(l.title, r.title, b && b.title)

        [
          %{
            kind: :changed,
            by: by,
            step: r.title,
            text:
              "#{who(by)} the title of step #{r.title}: #{from_to(by, l.title, r.title)}"
              |> no_base(by, "Step #{r.title} has a different title: yours “#{l.title}”")
          }
        ]
      else
        []
      end

    owner =
      if l.owner != r.owner do
        by = by(l.owner, r.owner, b && b.owner)

        text =
          case by do
            nil ->
              "Step #{r.title} has a different owner: yours #{owners(l)}, GitHub's #{owners(r)}"

            :local ->
              "You gave #{r.title} to #{owners(l)} (GitHub's has #{owners(r)})"

            _ ->
              "#{who_plain(by)} gives #{r.title} to #{owners(r)} (was #{owners(l)})"
          end

        [%{kind: :reowned, by: by, step: r.title, text: text}]
      else
        []
      end

    settings =
      [:approval, :optional, :on_reject]
      |> Enum.filter(&(Map.get(l, &1) != Map.get(r, &1)))

    settings_change =
      if settings != [] do
        by = by(Map.take(l, settings), Map.take(r, settings), b && Map.take(b, settings))
        names = Enum.map_join(settings, ", ", &setting_name/1)

        [
          %{
            kind: :changed,
            by: by,
            step: r.title,
            text:
              "#{who(by)} #{names} for #{r.title}"
              |> no_base(by, "Step #{r.title} has a different #{names}")
          }
        ]
      else
        []
      end

    instructions =
      if section(local, id) != section(remote, id) do
        by = by(section(local, id), section(remote, id), base && section(base, id))

        [
          %{
            kind: :changed,
            by: by,
            step: r.title,
            text:
              "#{who(by)} the instructions for #{r.title}"
              |> no_base(by, "The instructions for #{r.title} differ")
          }
        ]
      else
        []
      end

    title ++ owner ++ settings_change ++ instructions
  end

  defp setting_name(:approval), do: "the approval"
  defp setting_name(:optional), do: "whether it's optional"
  defp setting_name(:on_reject), do: "where a rejection goes back to"

  defp field_changes(local, remote, base) do
    for {field, label} <- @fields, Map.get(local, field) != Map.get(remote, field) do
      l = Map.get(local, field)
      r = Map.get(remote, field)
      by = by(l, r, base && Map.get(base, field))

      text =
        if short?(l) and short?(r),
          do:
            "#{who(by)} #{label}: #{from_to(by, l, r)}"
            |> no_base(by, "#{capital(label)} differs: yours #{quoted(l)}, GitHub's #{quoted(r)}"),
          else: "#{who(by)} #{label}" |> no_base(by, "#{capital(label)} differs")

      %{kind: :changed, by: by, step: nil, text: text}
    end
  end

  # A title only one side has isn't a change: the builder writes one on
  # every save, so a file without one would always differ
  defp title_change(local, remote, base) do
    l = title(local)
    r = title(remote)

    if l && r && l != r do
      by = by(l, r, base && (title(base) || :none))

      [
        %{
          kind: :changed,
          by: by,
          step: nil,
          text:
            "#{who(by)} the title: #{from_to(by, l, r)}"
            |> no_base(by, "The title differs: yours #{quoted(l)}, GitHub's #{quoted(r)}")
        }
      ]
    else
      []
    end
  end

  defp guidance_change(local, remote, base) do
    l = guidance(local)
    r = guidance(remote)

    if l != r do
      by = by(l, r, base && guidance(base))

      [
        %{
          kind: :changed,
          by: by,
          step: nil,
          text: "#{who(by)} the guidance" |> no_base(by, "The guidance differs")
        }
      ]
    else
      []
    end
  end

  # The guidance without its leading `# Title` line (the rule `Writer` reads
  # the title by), and that title or nil
  defp guidance(definition), do: definition |> split_title() |> elem(1)
  defp title(definition), do: definition |> split_title() |> elem(0)

  defp split_title(definition) do
    text = Definition.guidance(definition)
    [first | rest] = String.split(text, "\n", parts: 2)

    case Regex.run(~r/\A#[ \t]+(.+?)[ \t]*#*[ \t]*\z/, first) do
      [_, title] -> {String.trim(title), rest |> Enum.join() |> String.trim()}
      nil -> {nil, text}
    end
  end

  # who made a difference, from the base: nil without one
  defp by(_local, _remote, nil), do: nil
  defp by(local, _remote, base) when local == base, do: :remote
  defp by(_local, remote, base) when remote == base, do: :local
  defp by(_local, _remote, _base), do: :both

  defp who(:remote), do: "GitHub changed"
  defp who(:local), do: "You changed"
  defp who(:both), do: "Both changed"
  defp who(nil), do: nil

  defp who_plain(:remote), do: "GitHub"
  defp who_plain(:both), do: "Both"

  defp no_base(_text, nil, fallback), do: fallback
  defp no_base(text, _by, _fallback), do: text

  defp after_text(definition, id) do
    index = Enum.find_index(definition.steps, &(&1.id == id))

    case index && index > 0 && Enum.at(definition.steps, index - 1) do
      %{title: title} -> " after #{title}"
      _ -> " at the start"
    end
  end

  defp owners(%{owner: owner}), do: Enum.join(owner, ", ")

  defp short?(nil), do: true

  defp short?(value) when is_binary(value),
    do: String.length(value) <= @short and not String.contains?(value, "\n")

  defp short?(value) when is_integer(value), do: true
  defp short?(_), do: false

  # old → new: your change runs from GitHub's (the base) to yours
  defp from_to(:local, l, r), do: "#{quoted(r)} → #{quoted(l)}"
  defp from_to(_by, l, r), do: "#{quoted(l)} → #{quoted(r)}"

  defp quoted(nil), do: "(none)"
  defp quoted(value), do: "“#{value}”"

  defp capital(label),
    do: String.capitalize(String.slice(label, 0, 1)) <> String.slice(label, 1..-1//1)

  # -- Instructions ---------------------------------------------------------------

  defp instructions(local, remote) do
    guidance =
      case {guidance(local), guidance(remote)} do
        {same, same} -> []
        {l, r} -> [%{step: nil} |> Map.merge(segs(l, r))]
      end

    local_ids = ids(local.steps)

    steps =
      for step <- remote.steps,
          step.id in local_ids,
          section(local, step.id) != section(remote, step.id) do
        Map.merge(%{step: step.title}, segs(section(local, step.id), section(remote, step.id)))
      end

    guidance ++ steps
  end

  defp new_instructions(remote) do
    guidance =
      case Definition.guidance(remote) do
        "" -> []
        text -> [%{step: nil, local: [], remote: [{:ins, text}]}]
      end

    steps =
      Enum.map(remote.steps, fn step ->
        text = section(remote, step.id)
        %{step: step.title, local: [], remote: if(text == "", do: [], else: [{:ins, text}])}
      end)

    guidance ++ steps
  end

  @doc """
  A word-level diff, split per side: each side's segments join back into
  exactly its own text; `:ins` marks the words only that side has.
  """
  def segs(local, remote) do
    diff = word_diff(tokens(local), tokens(remote))

    local_segs =
      Enum.flat_map(diff, fn
        {:eq, t} -> [{:eq, Enum.join(t)}]
        {:del, t} -> [{:ins, Enum.join(t)}]
        {:ins, _} -> []
      end)

    remote_segs =
      Enum.flat_map(diff, fn
        {:eq, t} -> [{:eq, Enum.join(t)}]
        {:ins, t} -> [{:ins, Enum.join(t)}]
        {:del, _} -> []
      end)

    %{local: merge(local_segs), remote: merge(remote_segs)}
  end

  # Myers is quadratic on a full rewrite (seconds at 30 KB), so the common
  # head and tail are taken off first, and a middle over the budget is shown
  # as one change on each side
  @diff_budget 2_000

  defp word_diff(a, b) do
    {head, a, b} = common_head(a, b, [])
    {tail, a, b} = common_head(Enum.reverse(a), Enum.reverse(b), [])
    {a, b, tail} = {Enum.reverse(a), Enum.reverse(b), Enum.reverse(tail)}

    middle =
      if length(a) + length(b) > @diff_budget,
        do: [{:del, a}, {:ins, b}],
        else: List.myers_difference(a, b)

    [{:eq, head} | middle] ++ [{:eq, tail}]
  end

  defp common_head([x | a], [x | b], acc), do: common_head(a, b, [x | acc])
  defp common_head(a, b, acc), do: {Enum.reverse(acc), a, b}

  defp tokens(text), do: Regex.split(~r/(\s+)/, text, include_captures: true, trim: true)

  defp merge(segs) do
    segs
    |> Enum.reject(fn {_, t} -> t == "" end)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn [{kind, _} | _] = run -> {kind, Enum.map_join(run, &elem(&1, 1))} end)
  end

  # -- File diff ------------------------------------------------------------------

  @doc """
  A unified diff of the two files, with `--- yours vN` and `+++ GitHub vM`
  headers and #{@context} lines of context; yours carries its `version:`
  line, as an export would write it. `local` nil diffs from nothing.
  """
  def file_diff(local, remote, local_version, remote_version) do
    local_text =
      case local do
        nil -> nil
        text when is_integer(local_version) -> Text.put_version(text, local_version)
        text -> text
      end

    l = lines(local_text)
    r = lines(remote)

    ops =
      List.myers_difference(l, r)
      |> Enum.flat_map(fn {kind, ls} -> Enum.map(ls, &{kind, &1}) end)

    header =
      "--- " <>
        if(local == nil, do: "(not in your library)", else: "yours" <> label(local_version)) <>
        "\n+++ GitHub" <> label(remote_version) <> "\n"

    header <> hunks(ops)
  end

  defp label(nil), do: ""
  defp label(n), do: " v#{n}"

  defp lines(nil), do: []

  defp lines(text) do
    text |> String.replace("\r\n", "\n") |> String.trim_trailing("\n") |> String.split("\n")
  end

  defp hunks(ops) do
    # number each op with the line it sits at on each side
    {numbered, _} =
      Enum.map_reduce(ops, {1, 1}, fn
        {:eq, line}, {a, b} -> {{:eq, line, a, b}, {a + 1, b + 1}}
        {:del, line}, {a, b} -> {{:del, line, a, b}, {a + 1, b}}
        {:ins, line}, {a, b} -> {{:ins, line, a, b}, {a, b + 1}}
      end)

    indexed = Enum.with_index(numbered)
    changed = for {{kind, _, _, _}, i} <- indexed, kind != :eq, do: i

    case changed do
      [] ->
        ""

      _ ->
        changed
        |> group_ranges()
        |> Enum.map_join(fn {first, last} ->
          from = max(first - @context, 0)
          to = min(last + @context, length(numbered) - 1)
          hunk(Enum.slice(numbered, from..to))
        end)
    end
  end

  # change indexes grouped where the eq run between them fits in the context
  defp group_ranges([first | rest]) do
    {ranges, current} =
      Enum.reduce(rest, {[], {first, first}}, fn i, {acc, {s, e}} ->
        if i - e <= 2 * @context + 1, do: {acc, {s, i}}, else: {[{s, e} | acc], {i, i}}
      end)

    Enum.reverse([current | ranges])
  end

  defp hunk(ops) do
    a_count = Enum.count(ops, fn {k, _, _, _} -> k != :ins end)
    b_count = Enum.count(ops, fn {k, _, _, _} -> k != :del end)
    {_, _, a0, b0} = hd(ops)
    a_start = if a_count == 0, do: a0 - 1, else: a0
    b_start = if b_count == 0, do: b0 - 1, else: b0

    "@@ -#{a_start},#{a_count} +#{b_start},#{b_count} @@\n" <>
      Enum.map_join(ops, fn
        {:eq, line, _, _} -> " " <> line <> "\n"
        {:del, line, _, _} -> "-" <> line <> "\n"
        {:ins, line, _, _} -> "+" <> line <> "\n"
      end)
  end
end
