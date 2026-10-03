defmodule Canopy.Templates.Import do
  @moduledoc """
  Imports template files: `plan/2` reads them and works out what would happen
  without writing anything (the preview); `choose/2` applies the user's
  choices to the preview; `apply/2` writes it in one transaction, all or
  nothing.

  Sources are `{:file, filename, bytes}` (a `.md` file or a bundle `.zip`),
  `{:text, text}` (pasted), `{:gallery, name}` (a gallery agent) and
  `{:gallery_bundle, name}`.

  What an item becomes is checked where it will live:

    * agents go through `Agent.changeset/2` unchanged, so the name rules,
      enums and model rules have one source; a template can never grant
      bypass permissions;
    * a file made for another machine falls back, with a notice: an engine
      this Canopy doesn't know becomes the engine for new agents, a model
      this machine doesn't offer becomes the default model, an OpenCode
      agent it doesn't define becomes `plan` (least privilege). A model that
      can't be checked because OpenCode is away is kept, with a notice;
    * a taken name is a conflict: rename (the default, to a free `<name>-2`),
      replace (like saving the edit form: the id, channels, sessions,
      schedules and memory stay), or skip (references bind to the agent
      already here);
    * teams and playbooks in a bundle name agents: those resolve to the
      bundle's agents first (after renames, which rewrite the references),
      then to agents already here. A team member that resolves to nothing is
      an error; a playbook's, a notice, since the library accepts it and a
      run says what is missing. `@mentions` in prose are never rewritten;
      the preview says where a renamed name appears.
  """

  import Ecto.Query, warn: false

  alias Canopy.{Agents, Memory, Playbooks, Repo, Teams}
  alias Canopy.Agents.Agent
  alias Canopy.Playbooks.{Definition, Playbook}
  alias Canopy.Teams.Team
  alias Canopy.Templates
  alias Canopy.Templates.{AgentTemplate, Bundle, Gallery, Machine, TeamTemplate}
  alias Canopy.Templates.Import.{Item, Plan}
  alias Ecto.Multi

  @claude_fields ~w(display_name role group color engine permission_mode effort allowed_tools model_id
                    routing_enabled light_model_id light_effort system_prompt)a
  @opencode_fields ~w(display_name role group color engine opencode_agent model_provider model_id
                      routing_enabled light_model_provider light_model_id system_prompt)a
  @broad_tools ["*", "Bash", "Bash(*)", "Bash(* *)"]

  # -- Plan -----------------------------------------------------------------------

  @doc """
  The preview for `sources`; writes nothing. `machine:` (a
  `Canopy.Templates.Machine`) skips probing this machine, for tests.
  """
  def plan(sources, opts \\ []) when is_list(sources) do
    machine = Keyword.get_lazy(opts, :machine, &Machine.probe/0)

    {files, manifest, notices, errors} =
      Enum.reduce(sources, {[], nil, [], []}, fn source, {files, manifest, notices, errors} ->
        case read_source(source) do
          {:ok, more, m, n} -> {files ++ more, manifest || m, notices ++ n, errors}
          {:error, lines} -> {files, manifest, notices, errors ++ lines}
        end
      end)

    items =
      files
      |> Enum.with_index(1)
      |> Enum.map(fn {{path, text, opts}, n} -> decode_item(path, text, opts, n) end)

    errors =
      if errors == [] and items == [],
        do: ["nothing to import: the file holds no agents, teams or playbooks"],
        else: errors

    resolve(%Plan{
      items: items,
      manifest: manifest,
      notices: notices,
      errors: errors,
      sources: sources,
      machine: machine
    })
  end

  defp read_source({:file, name, bin}) when is_binary(bin) do
    cond do
      Bundle.zip?(bin) or String.ends_with?(String.downcase(name), ".zip") ->
        with {:ok, %{manifest: manifest, files: files, notices: notices}} <- Bundle.read(bin) do
          {:ok, Enum.map(files, fn {path, text} -> {path, text, []} end), manifest, notices}
        end

      not String.valid?(bin) ->
        {:error, ["#{name} isn't a text file"]}

      true ->
        {:ok, [{name, bin, []}], nil, []}
    end
  end

  defp read_source({:text, text}) when is_binary(text) do
    if String.trim(text) == "",
      do: {:error, ["paste a template first"]},
      else: {:ok, [{"pasted text", text, []}], nil, []}
  end

  defp read_source({:gallery, name}) do
    case Gallery.agent_text(name) do
      nil -> {:error, ["the gallery has no agent named #{name}"]}
      text -> {:ok, [{"#{name}.md", text, [gallery: true]}], nil, []}
    end
  end

  defp read_source({:gallery_bundle, name}) do
    case Gallery.bundle(name) do
      nil ->
        {:error, ["the gallery has no bundle named #{name}"]}

      %{files: files} = bundle ->
        manifest = %{"name" => bundle.name, "description" => bundle.description}

        files =
          files
          |> Enum.reject(fn {path, _} -> path == "canopy.md" end)
          |> Enum.map(fn {path, text} -> {path, text, [gallery: true]} end)

        {:ok, files, manifest, []}
    end
  end

  defp decode_item(path, text, opts, n) do
    base = %Item{id: "item-#{n}", path: path}

    case Templates.decode(text, opts) do
      {:ok, :agent, template} ->
        memory_errors =
          if template.memory && byte_size(template.memory) > Memory.max_bytes(),
            do: ["the memory is over #{div(Memory.max_bytes(), 1024)} KB"],
            else: []

        %{
          base
          | kind: :agent,
            name: normalize(template.name),
            template: template,
            memory: template.memory,
            file_errors: memory_errors,
            file_notices: template.warnings
        }

      {:ok, :team, template} ->
        %{
          base
          | kind: :team,
            name: template.name,
            template: template,
            file_notices: template.warnings
        }

      {:ok, :playbook, text} ->
        case Definition.parse(text) do
          {:ok, definition} ->
            %{
              base
              | kind: :playbook,
                name: definition.name,
                template: text,
                file_notices: definition.warnings
            }

          {:error, reasons} ->
            %{base | kind: :playbook, name: Path.basename(path, ".md"), file_errors: reasons}
        end

      {:error, reasons} ->
        %{
          base
          | kind: kind_from_path(path),
            name: Path.basename(path, ".md"),
            file_errors: reasons
        }
    end
  end

  defp kind_from_path("teams/" <> _), do: :team
  defp kind_from_path("playbooks/" <> _), do: :playbook
  defp kind_from_path(_), do: :agent

  # -- Choices ----------------------------------------------------------------------

  @doc """
  Applies the user's picks to the preview and works it out again. `choices`
  maps an item id to any of `"action"`, `"name"`, `"memory"`, `"engine"`
  (strings, as a form sends them, or atoms).
  """
  def choose(%Plan{} = plan, choices) when is_map(choices) do
    items =
      Enum.map(plan.items, fn item ->
        case Map.get(choices, item.id) do
          %{} = choice -> %{item | picked: merge_picks(item.picked, choice)}
          _ -> item
        end
      end)

    resolve(%{plan | items: items})
  end

  defp merge_picks(picked, choice) do
    Enum.reduce(choice, picked, fn {key, value}, acc ->
      case {to_string(key), value} do
        {"action", v} when v in ["create", "rename", "replace", "skip"] ->
          Map.put(acc, :action, String.to_existing_atom(v))

        {"action", v} when v in [:create, :rename, :replace, :skip] ->
          Map.put(acc, :action, v)

        {"name", v} when is_binary(v) ->
          Map.put(acc, :name, normalize(v))

        {"memory", v} when v in ["import", "skip", "keep", "replace", "append"] ->
          Map.put(acc, :memory, String.to_existing_atom(v))

        {"memory", v} when v in [:import, :skip, :keep, :replace, :append] ->
          Map.put(acc, :memory, v)

        {"engine", v} when is_binary(v) ->
          if v in Canopy.Engine.names(), do: Map.put(acc, :engine, v), else: acc

        _ ->
          acc
      end
    end)
  end

  # -- Working it out -------------------------------------------------------------

  # Everything after decoding, from the database, the machine, and the picks:
  # each item's status, then the choices, then what teams and playbooks
  # resolve to (which depends on the agents' choices), then the names.
  defp resolve(%Plan{} = plan) do
    items =
      Enum.map(plan.items, fn
        %Item{kind: :agent} = item -> fit_agent(item, plan.machine)
        %Item{kind: :team} = item -> status_team(item)
        %Item{kind: :playbook} = item -> status_playbook(item)
      end)

    %{plan | items: items}
    |> put_choices()
    |> resolve_teams()
    |> check_names()
    |> resolve_playbooks()
    |> mention_notices()
  end

  # An agent: the engine and attrs for this machine, then its status.
  defp fit_agent(%Item{template: nil} = item, _machine),
    do: %{item | status: :invalid, errors: item.file_errors, notices: item.file_notices}

  defp fit_agent(%Item{template: t} = item, machine) do
    known? = t.engine in Canopy.Engine.names()

    engine =
      item.picked[:engine] || if(known?, do: t.engine, else: Machine.default_engine(machine))

    engine_notices =
      if t.engine && not known?,
        do: ["engine #{t.engine} isn't supported here; using #{Canopy.Engine.label(engine)}"],
        else: []

    {attrs, attr_notices} = AgentTemplate.attrs(t, engine)
    {attrs, machine_notices} = fit_machine(attrs, machine)

    existing = Agents.get_by_name(item.name)
    team_clash? = not is_nil(Teams.get_by_name(item.name))

    errors =
      item.file_errors ++
        (%Agent{}
         |> Agent.changeset(attrs)
         |> changeset_errors()
         |> Enum.reject(&String.contains?(&1, "is already a team's name")))

    {diff, prompt_diff} = if existing, do: diff(existing, attrs), else: {[], nil}

    status =
      cond do
        errors != [] -> :invalid
        existing && diff == [] && memory_same?(existing, item.memory) -> :identical
        existing || team_clash? -> :conflict
        true -> :new
      end

    deactivated =
      if existing && not existing.active,
        do: ["@#{existing.name} here is deactivated; replacing it keeps it deactivated"],
        else: []

    clash =
      if team_clash? and is_nil(existing),
        do: ["@#{item.name} is a team's name here; agents and teams share @names"],
        else: []

    %{
      item
      | engine: engine,
        attrs: attrs,
        status: status,
        existing: existing,
        diff: diff,
        prompt_diff: prompt_diff,
        permission: permission(attrs),
        errors: errors,
        notices:
          item.file_notices ++
            engine_notices ++ attr_notices ++ machine_notices ++ deactivated ++ clash
    }
  end

  # Fallbacks for what this machine has; each one says what it did.
  defp fit_machine(%{engine: "claude_code"} = attrs, machine) do
    if machine.claude_code,
      do: {attrs, []},
      else:
        {attrs, ["Claude Code isn't installed on this machine; the agent won't run until it is"]}
  end

  defp fit_machine(%{engine: "opencode"} = attrs, machine) do
    {attrs, model_notices} = fit_opencode_model(attrs, machine.opencode)
    {attrs, agent_notices} = fit_opencode_agent(attrs, machine.opencode_agents)

    reach =
      if Machine.opencode_reachable?(machine),
        do: [],
        else: ["OpenCode isn't reachable right now; the agent won't run until it is"]

    {attrs, reach ++ model_notices ++ agent_notices}
  end

  defp fit_machine(attrs, _machine), do: {attrs, []}

  defp fit_opencode_model(%{model_id: nil} = attrs, _opencode), do: {attrs, []}

  defp fit_opencode_model(%{model_provider: p, model_id: m} = attrs, {:ok, providers}) do
    available? =
      case Enum.find(providers, &(&1.id == p)) do
        %{models: models} -> m in models
        nil -> false
      end

    if available?,
      do: {attrs, []},
      else:
        {%{attrs | model_provider: nil, model_id: nil},
         ["model #{p}/#{m} isn't available from OpenCode here; the agent uses the default model"]}
  end

  defp fit_opencode_model(%{model_provider: p, model_id: m} = attrs, _away) do
    {attrs, ["couldn't check model #{p}/#{m} while OpenCode is away; kept"]}
  end

  defp fit_opencode_agent(%{opencode_agent: name} = attrs, known) do
    cond do
      name in Machine.builtin_opencode_agents() ->
        {attrs, []}

      is_list(known) and name not in known ->
        {%{attrs | opencode_agent: "plan"},
         ["OpenCode agent #{name} isn't defined here; using plan (read-only) instead"]}

      is_list(known) ->
        {attrs, []}

      true ->
        {attrs, ["couldn't check OpenCode agent #{name} while OpenCode is away; kept"]}
    end
  end

  defp memory_same?(_existing, nil), do: true

  defp memory_same?(existing, memory),
    do: String.trim(Memory.get(existing.id)) == String.trim(memory)

  # Field changes an import would make to `existing`, and a line diff of the
  # prompt when it changes. Only the fields the engine uses count.
  defp diff(existing, attrs) do
    fields = if attrs.engine == "claude_code", do: @claude_fields, else: @opencode_fields

    changes =
      Enum.flat_map(fields, fn field ->
        old = compare_value(field, existing, existing)
        new = compare_value(field, attrs, existing)
        if old == new, do: [], else: [{field, old, new}]
      end)

    prompt_diff =
      if Enum.any?(changes, &(elem(&1, 0) == :system_prompt)),
        do:
          List.myers_difference(
            String.split(String.trim(existing.system_prompt || ""), "\n"),
            String.split(String.trim(attrs.system_prompt || ""), "\n")
          )

    {changes, prompt_diff}
  end

  defp compare_value(:routing_enabled, record, _existing),
    do: Map.get(record, :routing_enabled) == true

  defp compare_value(:allowed_tools, record, _existing),
    do: Agent.allowed_tools_list(%{allowed_tools: Map.get(record, :allowed_tools)})

  # a blank display name saves as the agent's name
  defp compare_value(:display_name, record, existing),
    do: text(Map.get(record, :display_name)) || existing.name

  defp compare_value(field, record, _existing), do: text(Map.get(record, field))

  defp text(nil), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(value), do: value

  @doc """
  The permission line for an agent's attrs: `%{text, risky}`. Risky (shown
  amber) when it edits without asking or approves broad tool patterns.
  """
  def permission(%{engine: "claude_code"} = attrs) do
    tools = Agent.allowed_tools_list(%{allowed_tools: attrs.allowed_tools})

    tools_text =
      case tools do
        [] -> "no extra tools approved"
        list -> "runs without asking: " <> Enum.join(list, ", ")
      end

    %{
      text: "Claude Code · #{attrs.permission_mode} · #{tools_text}",
      risky: attrs.permission_mode == "acceptEdits" or Enum.any?(tools, &(&1 in @broad_tools))
    }
  end

  def permission(%{engine: engine} = attrs) do
    %{
      text: "#{Canopy.Engine.label(engine)} · agent #{attrs[:opencode_agent]}",
      risky: attrs[:opencode_agent] == "build"
    }
  end

  # A team's status before its members are resolved: a taken name is a
  # conflict (resolve_teams/1 tells identical apart).
  defp status_team(%Item{template: nil} = item),
    do: %{item | status: :invalid, errors: item.file_errors, notices: item.file_notices}

  defp status_team(%Item{template: t} = item) do
    existing = Teams.get_by_name(t.name)
    agent_clash? = is_nil(existing) and not is_nil(Agents.get_by_name(t.name))

    errors =
      %Team{}
      |> Team.changeset(
        %{
          name: t.name,
          display_name: t.display_name,
          description: t.description,
          lead_agent_id: "x"
        },
        ["x"]
      )
      |> changeset_errors()
      |> Enum.reject(&String.contains?(&1, "is already an agent's name"))

    status =
      cond do
        errors != [] -> :invalid
        existing || agent_clash? -> :conflict
        true -> :new
      end

    clash =
      if agent_clash?,
        do: ["@#{t.name} is an agent's name here; agents and teams share @names"],
        else: []

    %{
      item
      | existing: existing,
        status: status,
        errors: errors,
        notices: item.file_notices ++ clash
    }
  end

  defp status_playbook(%Item{template: nil} = item),
    do: %{item | status: :invalid, errors: item.file_errors, notices: item.file_notices}

  defp status_playbook(%Item{template: text} = item) do
    existing = Playbooks.get_by_name(item.name)

    status =
      cond do
        is_nil(existing) -> :new
        String.trim(existing.body) == String.trim(text) -> :identical
        true -> :conflict
      end

    %{
      item
      | existing: existing,
        status: status,
        body: text,
        errors: [],
        notices: item.file_notices
    }
  end

  # In order, so two items renamed in one import get different names.
  defp put_choices(%Plan{} = plan) do
    {items, _} =
      Enum.map_reduce(plan.items, [], fn item, given ->
        item = put_choice(item, plan.items, given)
        {item, if(item.choice.name, do: [item.choice.name | given], else: given)}
      end)

    %{plan | items: items}
  end

  # The choice from the user's picks where the status offers them, else the
  # default: rename to a free name, keep or import memory. `given` are names
  # already suggested to earlier items.
  defp put_choice(%Item{} = item, items, given \\ []) do
    action =
      if item.picked[:action] in Item.actions(item),
        do: item.picked[:action],
        else: Item.default_action(item)

    memory =
      cond do
        is_nil(item.memory) ->
          nil

        action == :replace and item.picked[:memory] in [:keep, :replace, :append] ->
          item.picked[:memory]

        action == :replace ->
          :keep

        item.picked[:memory] in [:import, :skip] ->
          item.picked[:memory]

        true ->
          :import
      end

    name =
      if action == :rename,
        do:
          if(blank?(item.picked[:name]),
            do: suggest(item, items, given),
            else: item.picked[:name]
          )

    %{item | choice: %{action: action, name: name, memory: memory, engine: item.engine}}
  end

  @doc false
  # `<name>-2`, `-3`, … within 40 characters: free here, and not a name any
  # other item of the import has or was given.
  def suggest(%Item{} = item, items, given \\ []) do
    playbook? = item.kind == :playbook

    in_import =
      items
      |> Enum.filter(&(&1.id != item.id and &1.kind == :playbook == playbook?))
      |> Enum.flat_map(&[&1.name, &1.picked[:name]])
      |> Enum.concat(given)
      |> MapSet.new()

    base = item.name || "imported"

    Stream.iterate(2, &(&1 + 1))
    |> Stream.map(fn n ->
      suffix = "-#{n}"

      base
      |> String.slice(0, 40 - String.length(suffix))
      |> String.trim_trailing("-")
      |> Kernel.<>(suffix)
    end)
    |> Enum.find(&(not MapSet.member?(in_import, &1) and not taken_here?(item.kind, &1)))
  end

  # The name each written item takes must be valid and free, here and among
  # the other written items of its namespace (agents and teams share @names).
  defp check_names(%Plan{} = plan) do
    {items, _claimed} =
      Enum.map_reduce(plan.items, %{}, fn item, claimed ->
        if Item.writes?(item) do
          space = if item.kind == :playbook, do: :playbook, else: :at
          name = Item.target_name(item)
          errors = name_errors(item, name, Map.get(claimed, {space, name}))
          {%{item | errors: item.errors ++ errors}, Map.put(claimed, {space, name}, item.id)}
        else
          {item, claimed}
        end
      end)

    %{plan | items: items}
  end

  defp name_errors(_item, _name, taken) when is_binary(taken),
    do: ["another item in this import is also named that; rename one"]

  defp name_errors(%Item{choice: %{action: :rename}} = item, name, nil) do
    format =
      case item.kind do
        :playbook ->
          if Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, name) and String.length(name) in 2..40,
            do: [],
            else: ["name must be kebab-case, 2 to 40 characters"]

        _ ->
          if Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, name) and String.length(name) <= 40,
            do: [],
            else: ["name must be lowercase letters, digits, dashes or underscores (at most 40)"]
      end

    if format == [] and taken_here?(item.kind, name),
      do: ["#{name} is already taken here"],
      else: format
  end

  defp name_errors(_item, _name, nil), do: []

  defp taken_here?(:playbook, name), do: not is_nil(Playbooks.get_by_name(name))

  defp taken_here?(_kind, name),
    do: not is_nil(Agents.get_by_name(name)) or not is_nil(Teams.get_by_name(name))

  # What each agent name in the file stands for after this import:
  # `{:bundle, new_name}` for an agent item being written, `:skipped`
  # otherwise (references then bind to the agent already here).
  defp agent_index(%Plan{items: items}) do
    items
    |> Enum.filter(&(&1.kind == :agent and &1.status != :invalid))
    |> Map.new(fn item ->
      {item.name, if(Item.writes?(item), do: {:bundle, Item.target_name(item)}, else: :skipped)}
    end)
  end

  defp resolve_agent(index, name) do
    case Map.get(index, name) do
      {:bundle, target} ->
        {:bundle, target}

      _ ->
        case Agents.get_by_name(name) do
          %Agent{name: here} -> {:here, here}
          nil -> nil
        end
    end
  end

  defp resolved_name({_, name}), do: name
  defp resolved_name(_), do: nil

  # Members and the lead, through the agents' choices; a team already here
  # with the same fields, lead, members and roles is identical.
  defp resolve_teams(%Plan{} = plan) do
    index = agent_index(plan)

    items =
      Enum.map(plan.items, fn
        %Item{kind: :team, template: %TeamTemplate{} = t, status: status} = item
        when status != :invalid ->
          members =
            Enum.map(t.members, &Map.put(&1, :resolved, resolve_agent(index, &1.name)))

          item = %{item | members: members}

          item =
            if identical_team?(item),
              do: %{item | status: :identical} |> put_choice(plan.items),
              else: item

          missing =
            members
            |> Enum.filter(&is_nil(&1.resolved))
            |> Enum.map(&"member @#{&1.name} isn't in this import or on this machine")

          renamed =
            Enum.flat_map(members, fn
              %{name: old, resolved: {:bundle, new}} when new != old -> ["@#{old} → @#{new}"]
              _ -> []
            end)

          rename_notice =
            if renamed == [],
              do: [],
              else: ["member references follow the renames: " <> Enum.join(renamed, ", ")]

          %{
            item
            | errors: item.errors ++ if(Item.writes?(item), do: missing, else: []),
              notices: item.notices ++ rename_notice
          }

        item ->
          item
      end)

    %{plan | items: items}
  end

  defp identical_team?(%Item{existing: %Team{} = team, template: t, members: members}) do
    roles = Teams.member_roles(team)
    here = team.members |> Enum.map(&{&1.name, Map.get(roles, &1.id)}) |> Enum.sort()

    incoming =
      members
      |> Enum.map(&{resolved_name(&1.resolved) || &1.name, &1.role})
      |> Enum.sort()

    lead = Enum.find(members, &(&1.name == t.lead))
    lead_name = lead && (resolved_name(lead.resolved) || lead.name)

    team.display_name == (t.display_name || t.name) and team.description == t.description and
      not is_nil(team.lead) and team.lead.name == lead_name and here == incoming
  end

  defp identical_team?(_item), do: false

  # A playbook's references to teams and agents follow this import's renames
  # (only its frontmatter lines are rewritten); one that resolves to nothing
  # is a notice.
  defp resolve_playbooks(%Plan{} = plan) do
    agents = agent_index(plan)

    teams =
      plan.items
      |> Enum.filter(&(&1.kind == :team and &1.status != :invalid))
      |> Map.new(fn item ->
        {item.name, if(Item.writes?(item), do: {:bundle, Item.target_name(item)}, else: :skipped)}
      end)

    items =
      Enum.map(plan.items, fn
        %Item{kind: :playbook, template: text, status: status} = item
        when is_binary(text) and status != :invalid ->
          resolve_playbook(item, agents, teams)

        item ->
          item
      end)

    %{plan | items: items}
  end

  defp resolve_playbook(%Item{template: text} = item, agents, teams) do
    {:ok, d} = Definition.parse(text)

    agent_refs = [d.coordinator | Map.values(d.roles)] |> Enum.reject(&is_nil/1) |> Enum.uniq()
    resolved = Map.new(agent_refs, &{&1, resolve_agent(agents, &1)})

    team =
      d.team &&
        case Map.get(teams, d.team) do
          {:bundle, target} -> {:bundle, target}
          _ -> if Teams.get_by_name(d.team), do: {:here, d.team}
        end

    renames = for {old, {:bundle, new}} <- resolved, old != new, into: %{}, do: {old, new}

    team_rename =
      case team do
        {:bundle, new} when new != d.team -> new
        _ -> nil
      end

    {body, rewrite_errors} =
      rewrite_playbook(text, d, Item.target_name(item), renames, team_rename)

    missing =
      Enum.flat_map(Enum.sort(resolved), fn
        {name, nil} -> ["@#{name} isn't in this import or on this machine; a run will ask for it"]
        _ -> []
      end) ++
        if(d.team && is_nil(team),
          do: ["team @#{d.team} isn't in this import or on this machine"],
          else: []
        )

    %{
      item
      | body: body,
        errors: item.errors ++ if(Item.writes?(item), do: rewrite_errors, else: []),
        notices: item.notices ++ missing ++ rename_notices(renames, team_rename, d.team)
    }
  end

  defp rename_notices(renames, team_rename, old_team) do
    lines =
      Enum.map(renames, fn {old, new} -> "@#{old} → @#{new}" end) ++
        if(team_rename, do: ["team @#{old_team} → @#{team_rename}"], else: [])

    if lines == [], do: [], else: ["references follow the renames: " <> Enum.join(lines, ", ")]
  end

  @doc false
  # Rewrites a playbook's own name and its references, in the frontmatter
  # lines only, then checks the result says what was meant.
  def rewrite_playbook(text, %Definition{} = d, name, renames, team_rename) do
    if name == d.name and renames == %{} and is_nil(team_rename) do
      {text, []}
    else
      lines = String.split(text, "\n")

      case frontmatter_range(lines) do
        nil ->
          {text, ["couldn't rewrite the playbook's references"]}

        {first, last} ->
          {rewritten, _in_roles} =
            lines
            |> Enum.with_index()
            |> Enum.map_reduce(false, fn {line, i}, in_roles ->
              if i > first and i < last,
                do: rewrite_line(line, in_roles, name, d, renames, team_rename),
                else: {line, in_roles}
            end)

          new_text = Enum.join(rewritten, "\n")
          {new_text, check_rewrite(new_text, d, name, renames, team_rename)}
      end
    end
  end

  defp frontmatter_range(lines) do
    with first when is_integer(first) <- Enum.find_index(lines, &(String.trim(&1) == "---")),
         rest = Enum.drop(lines, first + 1),
         offset when is_integer(offset) <- Enum.find_index(rest, &(String.trim(&1) == "---")) do
      {first, first + 1 + offset}
    else
      _ -> nil
    end
  end

  # One frontmatter line, and whether the next is inside the `roles:` block.
  defp rewrite_line(line, in_roles, name, d, renames, team_rename) do
    cond do
      Regex.match?(~r/^name:/, line) ->
        {"name: " <> name, false}

      Regex.match?(~r/^roles:\s*$/, line) ->
        {line, true}

      team_rename && Regex.match?(~r/^team:/, line) ->
        {"team: " <> team_rename, false}

      Regex.match?(~r/^coordinator:/, line) and Map.has_key?(renames, d.coordinator) ->
        {"coordinator: " <> Map.fetch!(renames, d.coordinator), false}

      in_roles and Regex.match?(~r/^\s+\S/, line) ->
        case Regex.run(~r/^(\s+[^:\s]+:\s*)["']?@?([^"'\s#]+)["']?(\s*(?:#.*)?)$/, line) do
          [_, key, value, trailing] ->
            case Map.fetch(renames, value) do
              {:ok, new} -> {key <> new <> trailing, true}
              :error -> {line, true}
            end

          _ ->
            {line, true}
        end

      true ->
        {line, in_roles and not Regex.match?(~r/^\S/, line)}
    end
  end

  defp check_rewrite(text, d, name, renames, team_rename) do
    rename = &Map.get(renames, &1, &1)

    case Definition.parse(text) do
      {:ok, new} ->
        ok? =
          new.name == name and
            new.roles == Map.new(d.roles, fn {role, agent} -> {role, rename.(agent)} end) and
            new.coordinator == (d.coordinator && rename.(d.coordinator)) and
            new.team == (team_rename || d.team)

        if ok?,
          do: [],
          else: [
            "couldn't rewrite the playbook's references to follow the renames; keep the names, or edit it after importing"
          ]

      {:error, _} ->
        ["couldn't rewrite the playbook's references to follow the renames"]
    end
  end

  # A renamed agent's old @name in prose (prompts, playbooks) stays as it is;
  # the preview says where it appears.
  defp mention_notices(%Plan{} = plan) do
    texts =
      Enum.flat_map(plan.items, fn
        %Item{kind: :agent, attrs: %{system_prompt: p}} = i when is_binary(p) -> [{i, p}]
        %Item{kind: :playbook, body: b} = i when is_binary(b) -> [{i, b}]
        _ -> []
      end)

    items =
      Enum.map(plan.items, fn
        %Item{kind: :agent, choice: %{action: :rename}, name: old} = item when is_binary(old) ->
          mention = ~r/(?<![\w@])@#{Regex.escape(old)}(?![\w-])/

          case for({i, text} <- texts, Regex.match?(mention, text), do: Item.label(i)) do
            [] ->
              item

            where ->
              %{
                item
                | notices:
                    item.notices ++
                      [
                        "@#{old} is mentioned in #{Enum.join(where, ", ")}; mentions in prose aren't rewritten"
                      ]
              }
          end

        item ->
          item
      end)

    %{plan | items: items}
  end

  # -- Apply ------------------------------------------------------------------------

  @doc """
  Writes the preview, with `choices` applied first, in one transaction:
  `{:ok, summary}`, `{:error, :stale}` when anything it read changed since
  (work out the preview again), `{:error, :invalid}` when an item to write
  has errors, or `{:error, {label, lines}}` when a write is refused.
  Memory is written after the commit, so a rolled-back import tells no one.
  """
  def apply(%Plan{} = plan, choices \\ %{}) do
    plan = if choices == %{}, do: plan, else: choose(plan, choices)

    if Plan.ready?(plan) do
      plan
      |> multi()
      |> Repo.transaction(mode: :immediate)
      |> case do
        {:ok, changes} ->
          after_commit(plan, changes)
          {:ok, summary(plan)}

        {:error, :fresh, :stale, _} ->
          {:error, :stale}

        {:error, {{:team, id}, _step}, %Ecto.Changeset{} = changeset, _} ->
          item = Enum.find(plan.items, &(&1.id == id))
          {:error, {Item.label(item), changeset_errors(changeset)}}

        {:error, {_kind, id}, %Ecto.Changeset{} = changeset, _} ->
          item = Enum.find(plan.items, &(&1.id == id))
          {:error, {Item.label(item), changeset_errors(changeset)}}

        {:error, _step, reason, _} ->
          {:error, {"the import", [inspect(reason)]}}
      end
    else
      {:error, :invalid}
    end
  end

  defp multi(%Plan{} = plan) do
    writing = Plan.writing(plan)

    Multi.new()
    |> Multi.run(:fresh, fn _repo, _ -> check_fresh(plan) end)
    |> then(fn multi ->
      Enum.reduce(writing, multi, fn
        %Item{kind: :agent} = item, multi -> agent_step(multi, item)
        _item, multi -> multi
      end)
    end)
    |> then(fn multi ->
      Enum.reduce(writing, multi, fn
        %Item{kind: :team} = item, multi -> team_step(multi, item)
        %Item{kind: :playbook} = item, multi -> playbook_step(multi, item)
        _item, multi -> multi
      end)
    end)
  end

  # The preview again, from inside the transaction: anything that would come
  # out differently (a name taken meanwhile, an agent edited) is stale.
  defp check_fresh(%Plan{} = plan) do
    fresh = resolve(plan)

    same? =
      Enum.zip(plan.items, fresh.items)
      |> Enum.all?(fn {a, b} ->
        a.status == b.status and a.choice == b.choice and a.errors == b.errors and
          signature(a.existing) == signature(b.existing)
      end)

    if same?, do: {:ok, :fresh}, else: {:error, :stale}
  end

  defp signature(nil), do: nil
  defp signature(%{id: id, updated_at: at}), do: {id, at}

  defp agent_step(multi, %Item{choice: %{action: :replace}, existing: %Agent{} = agent} = item) do
    Multi.update(multi, {:agent, item.id}, Agent.changeset(agent, item.attrs))
  end

  defp agent_step(multi, %Item{} = item) do
    attrs = Map.put(item.attrs, :name, Item.target_name(item))
    Multi.insert(multi, {:agent, item.id}, Agent.changeset(%Agent{}, attrs))
  end

  defp team_step(multi, %Item{template: t} = item) do
    Multi.merge(multi, fn _changes ->
      names = Enum.map(item.members, &(resolved_name(&1.resolved) || &1.name))
      ids = Agents.ids_by_names(names)
      lead = Enum.find(item.members, &(&1.name == t.lead))
      member_ids = Enum.flat_map(names, &List.wrap(Map.get(ids, &1)))

      roles =
        Map.new(item.members, fn m ->
          {Map.get(ids, resolved_name(m.resolved) || m.name), m.role || ""}
        end)
        |> Map.delete(nil)

      attrs = %{
        name: Item.target_name(item),
        display_name: t.display_name,
        description: t.description,
        lead_agent_id: Map.get(ids, resolved_name(lead.resolved) || lead.name),
        agent_ids: member_ids,
        roles: roles
      }

      team =
        case item do
          %Item{choice: %{action: :replace}, existing: %Team{} = existing} -> existing
          _ -> %Team{}
        end

      Teams.save_multi(team, attrs, {:team, item.id})
    end)
  end

  defp playbook_step(multi, %Item{choice: %{action: :replace}, existing: %Playbook{} = p} = item) do
    changeset =
      p
      |> Playbook.changeset(%{body: item.body, source: "user"})
      |> Ecto.Changeset.optimistic_lock(:lock_version)

    Multi.update(multi, {:playbook, item.id}, changeset, stale_error_field: :lock_version)
  end

  defp playbook_step(multi, %Item{} = item) do
    Multi.insert(
      multi,
      {:playbook, item.id},
      Playbook.changeset(%Playbook{}, %{body: item.body, enabled: true, source: "user"})
    )
  end

  defp after_commit(%Plan{} = plan, changes) do
    for %Item{kind: :agent, memory: memory} = item when is_binary(memory) <- Plan.writing(plan) do
      %Agent{id: id} = Map.fetch!(changes, {:agent, item.id})

      case item.choice.memory do
        :import -> Memory.put(id, memory)
        :replace -> Memory.put(id, memory)
        :append -> Memory.append(id, memory)
        _ -> :ok
      end
    end

    kinds = plan |> Plan.writing() |> MapSet.new(& &1.kind)
    if MapSet.member?(kinds, :team), do: Teams.broadcast_changed()
    if MapSet.member?(kinds, :playbook), do: Playbooks.broadcast_changed()
    :ok
  end

  @doc """
  What an import did, by kind: `%{imported: [label], replaced: [label],
  skipped: [label]}`.
  """
  def summary(%Plan{items: items}) do
    Enum.reduce(items, %{imported: [], replaced: [], skipped: []}, fn item, acc ->
      key =
        case item.choice.action do
          :replace -> :replaced
          :skip -> :skipped
          _ -> :imported
        end

      Map.update!(acc, key, &(&1 ++ [Item.label(item)]))
    end)
  end

  @doc "The summary as one sentence: \"Imported @a and @b; replaced @c; skipped @d.\""
  def summary_text(%{imported: imported, replaced: replaced, skipped: skipped}) do
    [
      imported != [] && "Imported #{join(imported)}",
      replaced != [] && "replaced #{join(replaced)}",
      skipped != [] && "skipped #{join(skipped)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
    |> case do
      "" -> "Nothing to import."
      text -> String.upcase(String.first(text)) <> String.slice(text, 1..-1//1) <> "."
    end
  end

  defp join([one]), do: one
  defp join(list), do: Enum.join(Enum.drop(list, -1), ", ") <> " and " <> List.last(list)

  # -- Helpers ----------------------------------------------------------------------

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
  end

  defp normalize(nil), do: nil

  defp normalize(name) when is_binary(name),
    do: name |> String.trim() |> String.trim_leading("@") |> String.downcase()

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
