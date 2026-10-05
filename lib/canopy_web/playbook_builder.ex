defmodule CanopyWeb.PlaybookBuilder do
  @moduledoc """
  The playbook builder's draft, and everything done to it, for
  `CanopyWeb.PlaybookBuilderLive`. A draft is `Canopy.Playbooks.Writer`'s
  map, with two additions per step the file never sees: `uid` (stable while
  steps move) and `fresh` (added since the last save, so its key still
  follows its title).

  `text/1` is what Save writes; `problems/2` says, in the builder's words,
  what stops that text from parsing, attached to the step it is about.
  Pure.
  """

  alias Canopy.Playbooks.{Definition, Writer}

  @max_steps 20

  def max_steps, do: @max_steps

  # -- Loading ----------------------------------------------------------------------

  @doc "The draft of a parsed definition."
  def load(%Definition{} = definition) do
    definition
    |> Writer.draft()
    |> Map.update!(:steps, fn steps ->
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {s, n} -> Map.merge(s, %{uid: "s#{n}", fresh: false}) end)
    end)
    |> then(&Map.put(&1, :uid_seq, length(&1.steps)))
    |> Map.put(:name_follows_title, false)
  end

  @doc "A new playbook: one empty step, and a name that follows the title until saved."
  def blank do
    Writer.blank()
    |> Map.put(:name_follows_title, true)
    |> Map.put(:steps, [empty_step("s1")])
  end

  @doc "A copy of a draft as saved: every key frozen."
  def saved(draft) do
    draft
    |> Map.put(:name_follows_title, false)
    |> Map.update!(:steps, fn steps -> Enum.map(steps, &%{&1 | fresh: false}) end)
  end

  def empty_step(uid) do
    %{
      uid: uid,
      fresh: true,
      id: "",
      title: "",
      owner: [],
      on_reject: nil,
      approval: false,
      optional: false,
      instructions: "",
      done_when: ""
    }
  end

  @doc "The playbook's text for this draft."
  def text(draft), do: Writer.to_text(draft)

  @doc "`{:ok, definition}` or `{:error, reasons}` for the draft's text."
  def parse(draft), do: draft |> text() |> Definition.parse()

  # -- Keys ---------------------------------------------------------------------------

  @doc """
  Keeps derived keys current: a fresh step's key follows its title (unique,
  `-2` and on), and a new playbook's name follows its title.
  """
  def refresh(draft) do
    draft =
      if draft.name_follows_title,
        do: %{draft | name: Writer.slug(draft.title)},
        else: draft

    {steps, _taken} =
      draft.steps
      |> Enum.with_index(1)
      |> Enum.map_reduce(MapSet.new(frozen_ids(draft)), fn {step, n}, taken ->
        if step.fresh do
          base = Writer.slug(step.title, 30)
          base = if base == "", do: "step-#{n}", else: base
          id = unique(base, taken)
          {%{step | id: id}, MapSet.put(taken, id)}
        else
          {step, taken}
        end
      end)

    # a fresh step another step sends back to keeps that reference, unless
    # another step still has the old key (one restored by Undo, say): the
    # send-back is then that step's
    kept = MapSet.new(steps, & &1.id)

    renamed =
      Enum.zip(draft.steps, steps)
      |> Enum.filter(fn {a, b} -> a.id != b.id and a.id != "" and a.id not in kept end)
      |> Map.new(fn {a, b} -> {a.id, b.id} end)

    steps =
      Enum.map(steps, fn s ->
        if s.on_reject && Map.has_key?(renamed, s.on_reject),
          do: %{s | on_reject: renamed[s.on_reject]},
          else: s
      end)

    %{draft | steps: steps}
  end

  defp frozen_ids(draft), do: for(s <- draft.steps, not s.fresh, do: s.id)

  defp unique(base, taken) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc "Changes a step's key, rewriting every send-back that names it."
  def change_key(draft, uid, key) do
    key = Writer.slug(key, 30)
    step = step(draft, uid)

    cond do
      key == "" or is_nil(step) ->
        {:error, "A step key is lowercase words joined by dashes."}

      Enum.any?(draft.steps, &(&1.uid != uid and &1.id == key)) ->
        {:error, "Another step already uses #{key}."}

      true ->
        steps =
          Enum.map(draft.steps, fn s ->
            s = if s.on_reject == step.id, do: %{s | on_reject: key}, else: s
            if s.uid == uid, do: %{s | id: key, fresh: false}, else: s
          end)

        {:ok, %{draft | steps: steps}}
    end
  end

  # -- Steps --------------------------------------------------------------------------

  def step(draft, uid), do: Enum.find(draft.steps, &(&1.uid == uid))
  def position(draft, uid), do: Enum.find_index(draft.steps, &(&1.uid == uid))

  def update_step(draft, uid, fun) do
    %{draft | steps: Enum.map(draft.steps, &if(&1.uid == uid, do: fun.(&1), else: &1))}
  end

  # A uid no step has had in this draft: `uid_seq` only goes up, so a step
  # deleted and then restored by Undo never shares its uid with one added
  # in between.
  defp take_uid(draft) do
    n = max(Map.get(draft, :uid_seq, 0), highest_uid(draft)) + 1
    {"s#{n}", Map.put(draft, :uid_seq, n)}
  end

  defp highest_uid(draft) do
    draft.steps
    |> Enum.map(fn s ->
      case Integer.parse(String.trim_leading(s.uid, "s")) do
        {n, _} -> n
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Adds a step at `index` (0-based) from a preset: `task`, `parallel`,
  `review` (sends back to the step above), `sign_off` (the lead, your
  approval), `lead`. Returns `{draft, uid}`.
  """
  def add_step(draft, index, preset \\ "task") do
    {uid, draft} = take_uid(draft)
    above = if index > 0, do: Enum.at(draft.steps, index - 1)

    step =
      case preset do
        "review" ->
          %{empty_step(uid) | on_reject: above && above.id, title: "Review"}

        "sign_off" ->
          %{empty_step(uid) | owner: ["coordinator"], approval: true, title: "Your sign-off"}

        "lead" ->
          %{empty_step(uid) | owner: ["coordinator"]}

        _ ->
          empty_step(uid)
      end

    {%{draft | steps: List.insert_at(draft.steps, index, step)} |> refresh(), uid}
  end

  @doc "A copy of a step right after it. `{draft, uid}`."
  def duplicate_step(draft, uid) do
    case position(draft, uid) do
      nil ->
        {draft, nil}

      i ->
        {new_uid, draft} = take_uid(draft)
        source = Enum.at(draft.steps, i)

        # no key yet: the copy gets its own from its title, and send-backs
        # to the original stay with the original
        copy = %{source | uid: new_uid, id: "", fresh: true, title: source.title <> " (copy)"}
        {%{draft | steps: List.insert_at(draft.steps, i + 1, copy)} |> refresh(), new_uid}
    end
  end

  @doc """
  Deletes a step; send-backs to it are cleared. Returns `{draft, undo}`,
  where `undo` restores it with `restore/2`.
  """
  def delete_step(draft, uid) do
    case position(draft, uid) do
      nil ->
        {draft, nil}

      i ->
        step = Enum.at(draft.steps, i)
        senders = for s <- draft.steps, s.uid != uid, s.on_reject == step.id, do: s.uid

        steps =
          draft.steps
          |> List.delete_at(i)
          |> Enum.map(&if(&1.uid in senders, do: %{&1 | on_reject: nil}, else: &1))

        {%{draft | steps: steps}, %{step: step, index: i, senders: senders, position: i + 1}}
    end
  end

  def restore(draft, %{step: step, index: index, senders: senders}) do
    steps =
      draft.steps
      |> List.insert_at(min(index, length(draft.steps)), step)
      |> Enum.map(&if(&1.uid in senders, do: %{&1 | on_reject: step.id}, else: &1))

    refresh(%{draft | steps: steps})
  end

  @doc "Puts the steps in the order of `uids`; unknown uids are ignored, missing steps keep their place at the end."
  def reorder(draft, uids) do
    by_uid = Map.new(draft.steps, &{&1.uid, &1})

    ordered =
      uids |> Enum.map(&Map.get(by_uid, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.uid)

    rest = Enum.reject(draft.steps, &(&1.uid in Enum.map(ordered, fn s -> s.uid end)))
    %{draft | steps: ordered ++ rest}
  end

  @doc "Moves a step one place up (`-1`) or down (`1`)."
  def move(draft, uid, delta) do
    case position(draft, uid) do
      nil ->
        draft

      i ->
        j = i + delta

        if j < 0 or j >= length(draft.steps) do
          draft
        else
          step = Enum.at(draft.steps, i)
          %{draft | steps: draft.steps |> List.delete_at(i) |> List.insert_at(j, step)}
        end
    end
  end

  # -- Owners and roles -----------------------------------------------------------------

  @doc "Adds or removes `role` (or `coordinator`) as an owner of the step."
  def toggle_owner(draft, uid, role) do
    update_step(draft, uid, fn s ->
      if role in s.owner,
        do: %{s | owner: List.delete(s.owner, role)},
        else: %{s | owner: s.owner ++ [role]}
    end)
  end

  @doc "Adds a role (no-op when it exists). `agent` is its default agent's name, or nil."
  def add_role(draft, key, agent \\ nil) do
    if Enum.any?(draft.roles, &(&1.key == key)),
      do: draft,
      else: %{draft | roles: draft.roles ++ [%{key: key, agent: agent}]}
  end

  @doc "A role key no role uses yet: `role`, `role-2`, …"
  def free_role(draft, base \\ "role") do
    unique(
      Writer.slug(base, 30) |> then(&if(&1 == "", do: "role", else: &1)),
      MapSet.new(draft.roles, & &1.key)
    )
  end

  @doc "Renames a role everywhere it is used."
  def rename_role(draft, old, new) do
    new = Writer.slug(new, 30)

    cond do
      new == "" ->
        {:error, "A role name is a word or two."}

      new == old ->
        {:ok, draft}

      new == "coordinator" ->
        {:error, "Lead is already a role."}

      Enum.any?(draft.roles, &(&1.key == new)) ->
        {:error, "There is already a role called #{humanize(new)}."}

      true ->
        roles = Enum.map(draft.roles, &if(&1.key == old, do: %{&1 | key: new}, else: &1))

        steps =
          Enum.map(draft.steps, fn s ->
            %{s | owner: Enum.map(s.owner, &if(&1 == old, do: new, else: &1))}
          end)

        {:ok, %{draft | roles: roles, steps: steps}}
    end
  end

  def set_role_agent(draft, key, agent) do
    agent = if agent in [nil, ""], do: nil, else: agent

    %{
      draft
      | roles: Enum.map(draft.roles, &if(&1.key == key, do: %{&1 | agent: agent}, else: &1))
    }
  end

  def remove_role(draft, key), do: %{draft | roles: Enum.reject(draft.roles, &(&1.key == key))}

  @doc "The steps a role owns, as `{position, step}`."
  def role_uses(draft, key) do
    for {s, n} <- Enum.with_index(draft.steps, 1), key in s.owner, do: {n, s}
  end

  @doc "Roles every owner names, with ones only owners name added (no agent yet)."
  def sync_roles(draft) do
    used =
      draft.steps
      |> Enum.flat_map(& &1.owner)
      |> Enum.reject(&(&1 == "coordinator"))
      |> Enum.uniq()

    Enum.reduce(used, draft, &add_role(&2, &1))
  end

  def humanize("coordinator"), do: "Lead"
  def humanize(key), do: Writer.humanize(key)

  @doc """
  A parser or `Runs` message in the words the pages use: the coordinator is
  the lead, and `channel_name` is a channel name. Agents get the originals.
  """
  def plain_words(text) do
    text
    |> String.replace(~r/\bCoordinator\b/, "Lead")
    |> String.replace(~r/\bcoordinator\b/, "lead")
    |> String.replace(~r/\bwith channel_name\b/, "with a channel name")
    |> String.replace("channel_name", "channel name")
  end

  # -- Send-backs -----------------------------------------------------------------------

  @doc "The steps a step may send work back to: every earlier one."
  def send_back_targets(draft, uid) do
    case position(draft, uid) do
      nil -> []
      i -> Enum.take(draft.steps, i)
    end
  end

  @doc """
  The send-back rails, per step uid: `[%{lane, kind, label}]`, where kind is
  `:start` (the target), `:mid`, or `:end` (the sender). Overlapping loops
  get their own lanes; at most 3 are drawn.
  """
  def rails(draft) do
    index = draft.steps |> Enum.with_index() |> Map.new(fn {s, i} -> {s.id, i} end)

    loops =
      draft.steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {s, i} ->
        case s.on_reject && Map.get(index, s.on_reject) do
          t when is_integer(t) and t < i -> [{t, i, s}]
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {t, i, _} -> {i - t, t} end)

    {placed, _} =
      Enum.map_reduce(loops, [], fn {t, i, s}, used ->
        lane =
          Enum.find(0..10, fn lane ->
            not Enum.any?(used, fn {l, a, b} -> l == lane and a <= i and t <= b end)
          end)

        {{lane, t, i, s}, [{lane, t, i} | used]}
      end)

    placed
    |> Enum.filter(fn {lane, _, _, _} -> lane < 3 end)
    |> Enum.flat_map(fn {lane, t, i, sender} ->
      for row <- t..i do
        kind =
          cond do
            row == t -> :start
            row == i -> :end
            true -> :mid
          end

        {Enum.at(draft.steps, row).uid,
         %{
           lane: lane,
           kind: kind,
           label: "#{title(sender)} sends it back here when changes are requested"
         }}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  def title(%{title: title}) do
    case String.trim(title || "") do
      "" -> "Untitled step"
      t -> t
    end
  end

  # -- Problems -------------------------------------------------------------------------

  @doc """
  What stops the draft from saving, in plain words: `[%{uid, text, fixes}]`,
  `uid` nil for the playbook itself, `fixes` as `[{label, event, params}]`.
  Anything the parser still refuses that these checks do not name is added
  as it is, so Save is never enabled for a text that does not parse.
  """
  def problems(draft, parsed) do
    own = about_problems(draft) ++ role_problems(draft) ++ step_problems(draft)

    extra =
      case parsed do
        {:error, reasons} when own == [] ->
          Enum.map(
            reasons,
            &%{uid: nil, text: String.capitalize(plain_words(&1)) <> ".", fixes: []}
          )

        _ ->
          []
      end

    own ++ extra
  end

  defp about_problems(draft) do
    desc = String.trim(draft.description || "")

    [
      String.trim(draft.title || "") == "" && String.trim(draft.name || "") == "" &&
        "Give the playbook a name.",
      (String.trim(draft.name || "") != "" and
         not Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, draft.name)) &&
        "The name agents know it by must be lowercase words joined by dashes.",
      String.length(draft.name || "") > 40 && "The name agents know it by is over 40 characters.",
      desc == "" && "Say when to use this playbook, in the description.",
      String.length(desc) > 200 && "The description is over 200 characters.",
      draft.steps == [] && "A playbook needs at least one step."
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&%{uid: nil, text: &1, fixes: []})
  end

  defp role_problems(%{team: team}) when is_binary(team) and team != "", do: []

  defp role_problems(draft) do
    used = draft.steps |> Enum.flat_map(& &1.owner) |> MapSet.new()

    for %{key: key, agent: nil} <- draft.roles, MapSet.member?(used, key) do
      %{
        uid: nil,
        role: key,
        where: "Role · #{humanize(key)}",
        detail: "Has no agent. Choose one, or give the playbook a team.",
        text: "#{humanize(key)} has no agent. Choose one, or give the playbook a team.",
        fixes: []
      }
    end
  end

  defp step_problems(draft) do
    index = draft.steps |> Enum.with_index() |> Map.new(fn {s, i} -> {s.id, i} end)

    draft.steps
    |> Enum.with_index()
    |> Enum.flat_map(fn {s, i} ->
      where = "Step #{i + 1}"
      named = "#{where} · #{title(s)}"

      [
        String.trim(s.title || "") == "" &&
          %{
            uid: s.uid,
            where: where,
            detail: "Needs a title.",
            text: "#{where} needs a title.",
            fixes: []
          },
        s.owner == [] &&
          %{
            uid: s.uid,
            kind: :owner,
            where: named,
            detail: "Has nobody doing it.",
            text: "#{named} has nobody doing it.",
            fixes: []
          },
        send_back_problem(draft, s, i, index)
      ]
      |> Enum.filter(& &1)
      |> Enum.map(&Map.put_new(&1, :where, named))
    end)
  end

  defp send_back_problem(_draft, %{on_reject: nil}, _i, _index), do: nil

  defp send_back_problem(draft, s, i, index) do
    case Map.get(index, s.on_reject) do
      t when is_integer(t) and t < i ->
        nil

      t ->
        above = if i > 0, do: Enum.at(draft.steps, i - 1)

        detail =
          if t == nil,
            do: "sends work back to a step that no longer exists.",
            else:
              "sends work back to #{title(Enum.at(draft.steps, t))}, which now comes after it. Work can only go back to an earlier step."

        text = "#{title(s)} #{detail}"

        fixes =
          [
            above &&
              {"Send back to #{title(above)} instead", "set_send_back",
               %{"uid" => s.uid, "to" => above.id}},
            {"Don't send back", "set_send_back", %{"uid" => s.uid, "to" => ""}}
          ]
          |> Enum.filter(& &1)

        %{uid: s.uid, kind: :send_back, text: text, detail: upcase_first(detail), fixes: fixes}
    end
  end

  # String.capitalize/1 would lowercase the step titles in the rest
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
