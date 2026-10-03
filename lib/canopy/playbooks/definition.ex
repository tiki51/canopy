defmodule Canopy.Playbooks.Definition do
  @moduledoc """
  A playbook's text, parsed. One Markdown document: YAML frontmatter between
  `---` lines, then free guidance and an optional `## <step id>` section per
  step, which the coordinator is given when it reaches that step.

  Frontmatter fields: `name` (kebab-case, 2–40 chars), `description` (one
  sentence, at most 200 chars), `steps` (1–20 of `id`, `title`, `owner`, and
  optionally `approval: user`, `optional: true`, `on_reject: <earlier id>`),
  and optionally `roles` (role => default agent name), `team`, `coordinator`,
  `channel` (`current` or `new`), `inputs`, and `stall_after` (`30m`, `2h`, a
  number of minutes, or `off`; default 30 minutes).

  `owner` is a role, a list of roles (they work in parallel), or the reserved
  role `coordinator`. Pure: `parse/1` returns `{:ok, %Definition{}}` or
  `{:error, lines}`, human-readable reasons for the editor and for tools.
  Things that are probably mistakes but harmless (a section with no step)
  come back as `warnings` on the definition.
  """

  alias Canopy.Frontmatter

  @name_regex ~r/^[a-z0-9]+(-[a-z0-9]+)*$/
  @top_keys ~w(name description steps roles team coordinator channel inputs stall_after)
  @step_keys ~w(id title owner approval optional on_reject)
  @max_steps 20
  # read before the YAML parser sees anything, so it never works on more
  # (`Canopy.Frontmatter` also refuses anchors and aliases)
  @max_bytes 40_000
  @max_header_bytes 8_000
  @default_stall_minutes 30

  defstruct name: nil,
            description: nil,
            steps: [],
            roles: %{},
            team: nil,
            coordinator: nil,
            channel: "current",
            inputs: nil,
            stall_after: @default_stall_minutes,
            body: "",
            warnings: []

  @type step :: %{
          id: String.t(),
          title: String.t(),
          owner: [String.t()],
          approval: boolean(),
          optional: boolean(),
          on_reject: String.t() | nil
        }

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          steps: [step()],
          roles: %{String.t() => String.t()},
          team: String.t() | nil,
          coordinator: String.t() | nil,
          channel: String.t(),
          inputs: String.t() | nil,
          stall_after: pos_integer() | nil,
          body: String.t(),
          warnings: [String.t()]
        }

  @doc "The minutes a step may go quiet before Canopy nudges the coordinator, unless set."
  def default_stall_minutes, do: @default_stall_minutes

  @spec parse(String.t() | nil) :: {:ok, t()} | {:error, [String.t()]}
  def parse(text) when is_binary(text) do
    with {:ok, data, body} <-
           Frontmatter.read(text, "the playbook", @max_bytes, @max_header_bytes) do
      build_checked(data, body)
    end
  rescue
    # the checks below are meant to be total; anything they miss is still a
    # reason, never a crash
    e -> {:error, ["could not read the playbook: " <> Frontmatter.one_line(Exception.message(e))]}
  end

  def parse(_), do: {:error, ["the playbook is empty"]}

  @doc """
  The section a step's owner is given: the text under `## <step id>` up to
  the next `##` heading, trimmed; nil when the playbook has none.
  """
  def step_section(%__MODULE__{body: body}, step_id) do
    body
    |> sections()
    |> Enum.find_value(fn {heading, text} -> if heading == step_id, do: text end)
  end

  @doc "The guidance before the first step section, for the whole run."
  def guidance(%__MODULE__{body: body, steps: steps}) do
    ids = MapSet.new(steps, & &1.id)

    body
    |> String.split("\n")
    |> Enum.take_while(fn line ->
      case heading(line) do
        nil -> true
        h -> not MapSet.member?(ids, h)
      end
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  @doc "The step with this id, or nil."
  def step(%__MODULE__{steps: steps}, id), do: Enum.find(steps, &(&1.id == id))

  @doc "Every role a step names, other than `coordinator`, in order of first use."
  def owner_roles(%__MODULE__{steps: steps}) do
    steps |> Enum.flat_map(& &1.owner) |> Enum.reject(&(&1 == "coordinator")) |> Enum.uniq()
  end

  defp plain_keys?(map), do: Enum.all?(Map.keys(map), &is_binary/1)

  defp build_checked(data, body) do
    errors =
      unknown_keys(data, @top_keys, "")
      |> Kernel.++(check_name(data["name"]))
      |> Kernel.++(check_description(data["description"]))
      |> Kernel.++(check_optional_string(data, "team"))
      |> Kernel.++(check_optional_string(data, "coordinator"))
      |> Kernel.++(check_optional_string(data, "inputs"))
      |> Kernel.++(check_channel(data["channel"]))

    {roles, role_errors} = roles(data["roles"])
    {stall, stall_errors} = stall_after(Map.get(data, "stall_after", :default))
    team = blank_to_nil(data["team"])
    {steps, step_errors} = steps(data["steps"], roles, team)
    errors = errors ++ role_errors ++ stall_errors ++ step_errors

    if errors == [] do
      definition = %__MODULE__{
        name: data["name"],
        description: String.trim(data["description"]),
        steps: steps,
        roles: roles,
        team: team && String.trim_leading(team, "@"),
        coordinator: blank_to_nil(data["coordinator"]) |> strip_at(),
        channel: data["channel"] || "current",
        inputs: blank_to_nil(data["inputs"]),
        stall_after: stall,
        body: String.trim(body)
      }

      {:ok, %{definition | warnings: section_warnings(definition)}}
    else
      {:error, errors}
    end
  end

  defp unknown_keys(map, allowed, where) do
    case Map.keys(map) -- allowed do
      [] ->
        []

      keys ->
        Enum.map(keys, fn key ->
          "#{where}unknown field #{inspect(to_string(key))} (allowed: #{Enum.join(allowed, ", ")})"
        end)
    end
  end

  defp check_name(nil), do: ["name is missing"]

  defp check_name(name) when is_binary(name) do
    cond do
      String.length(name) < 2 or String.length(name) > 40 -> ["name must be 2 to 40 characters"]
      not Regex.match?(@name_regex, name) -> ["name must be kebab-case (bug-fix, release-notes)"]
      true -> []
    end
  end

  defp check_name(_), do: ["name must be text"]

  defp check_description(nil), do: ["description is missing"]

  defp check_description(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> ["description is missing"]
      String.length(String.trim(text)) > 200 -> ["description must be at most 200 characters"]
      true -> []
    end
  end

  defp check_description(_), do: ["description must be text"]

  defp check_optional_string(data, key) do
    case Map.get(data, key) do
      nil -> []
      value when is_binary(value) -> []
      _ -> ["#{key} must be text"]
    end
  end

  defp check_channel(nil), do: []
  defp check_channel(value) when value in ["current", "new"], do: []
  defp check_channel(_), do: ["channel must be current or new"]

  defp roles(nil), do: {%{}, []}

  defp roles(%{} = map) do
    Enum.reduce(map, {%{}, []}, fn {role, agent}, {acc, errors} ->
      cond do
        not is_binary(role) ->
          {acc, errors ++ ["roles: each role must be a plain name"]}

        role == "coordinator" ->
          {acc, errors ++ ["roles: coordinator is reserved for whoever runs the playbook"]}

        is_binary(agent) and String.trim(agent) != "" ->
          {Map.put(acc, role, strip_at(String.trim(agent))), errors}

        true ->
          {acc, errors ++ ["roles: #{role} must name an agent"]}
      end
    end)
  end

  defp roles(_), do: {%{}, ["roles must map each role to an agent name"]}

  defp stall_after(:default), do: {@default_stall_minutes, []}
  defp stall_after(value) when value in [false, "off", "never", "none"], do: {nil, []}

  defp stall_after(minutes) when is_integer(minutes) and minutes >= 1 and minutes <= 10_080,
    do: {minutes, []}

  defp stall_after(text) when is_binary(text) do
    case Regex.run(~r/\A\s*(\d+)\s*(m|min|mins|minutes|h|hr|hrs|hours|d|days?)\s*\z/i, text) do
      [_, n, unit] ->
        minutes =
          String.to_integer(n) *
            case String.downcase(unit) do
              "h" <> _ -> 60
              "d" <> _ -> 1440
              _ -> 1
            end

        stall_after(minutes)

      nil ->
        {nil, ["stall_after must be a duration such as 30m or 2h, or off"]}
    end
  end

  defp stall_after(_), do: {nil, ["stall_after must be between 1 minute and 7 days, or off"]}

  # -- Steps --------------------------------------------------------------------

  defp steps(nil, _roles, _team), do: {[], ["steps is missing"]}
  defp steps([], _roles, _team), do: {[], ["steps must list at least one step"]}

  defp steps(list, _roles, _team) when is_list(list) and length(list) > @max_steps,
    do: {[], ["at most #{@max_steps} steps"]}

  defp steps(list, roles, team) when is_list(list) do
    {steps, errors} =
      list
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {raw, n}, errors ->
        {step, step_errors} = step(raw, n, roles, team)
        {step, errors ++ step_errors}
      end)

    steps = Enum.reject(steps, &is_nil/1)
    {steps, errors ++ duplicate_ids(steps) ++ reject_targets(steps)}
  end

  defp steps(_, _roles, _team), do: {[], ["steps must be a list"]}

  defp step(%{} = raw, n, roles, team) do
    if plain_keys?(raw),
      do: plain_step(raw, n, roles, team),
      else: {nil, ["step #{n}: field names must be plain text"]}
  end

  defp step(_raw, n, _roles, _team), do: {nil, ["step #{n}: must be a set of fields"]}

  defp plain_step(raw, n, roles, team) do
    id = raw["id"]
    where = "step #{if is_binary(id), do: id, else: n}: "
    owner = owner_list(raw["owner"])

    errors =
      unknown_keys(raw, @step_keys, where)
      |> Kernel.++(check_step_id(id, where))
      |> Kernel.++(check_title(raw["title"], where))
      |> Kernel.++(check_owner(owner, roles, team, where))
      |> Kernel.++(check_flag(raw, "optional", where))
      |> Kernel.++(check_approval(raw["approval"], where))
      |> Kernel.++(
        if is_nil(raw["on_reject"]) or is_binary(raw["on_reject"]),
          do: [],
          else: [where <> "on_reject must be a step id"]
      )

    if errors == [] do
      {%{
         id: id,
         title: String.trim(raw["title"]),
         owner: owner,
         approval: raw["approval"] == "user",
         optional: raw["optional"] == true,
         on_reject: raw["on_reject"]
       }, []}
    else
      {nil, errors}
    end
  end

  defp check_title(title, where) when is_binary(title) do
    cond do
      String.trim(title) == "" -> [where <> "title is missing"]
      String.length(title) > 200 -> [where <> "title must be at most 200 characters"]
      true -> []
    end
  end

  defp check_title(_title, where), do: [where <> "title is missing"]

  defp check_step_id(id, where) when is_binary(id) do
    if Regex.match?(@name_regex, id),
      do: [],
      else: [where <> "id must be kebab-case (reproduce, sign-off)"]
  end

  defp check_step_id(_id, where), do: [where <> "id is missing"]

  defp owner_list(owner) when is_binary(owner), do: [strip_at(String.trim(owner))]

  defp owner_list(owners) when is_list(owners),
    do: owners |> Enum.filter(&is_binary/1) |> Enum.map(&strip_at(String.trim(&1))) |> Enum.uniq()

  defp owner_list(_), do: []

  defp check_owner([], _roles, _team, where), do: [where <> "owner is missing"]

  # With a team, roles come from its members' role labels (or names) when a
  # run starts, so any role may be named here.
  defp check_owner(_owner, _roles, team, _where) when is_binary(team), do: []

  defp check_owner(owner, roles, _team, where) do
    owner
    |> Enum.reject(&(&1 == "coordinator" or Map.has_key?(roles, &1)))
    |> Enum.map(&(where <> "owner role #{&1} is not defined in roles (or give a team)"))
  end

  defp check_flag(raw, key, where) do
    case Map.get(raw, key) do
      nil -> []
      value when is_boolean(value) -> []
      _ -> [where <> "#{key} must be true or false"]
    end
  end

  defp check_approval(nil, _where), do: []
  defp check_approval("user", _where), do: []
  defp check_approval(_, where), do: [where <> "approval must be user"]

  defp duplicate_ids(steps) do
    steps
    |> Enum.frequencies_by(& &1.id)
    |> Enum.filter(fn {_id, n} -> n > 1 end)
    |> Enum.map(fn {id, _} -> "duplicate step id #{id}" end)
  end

  # on_reject goes back to an earlier step, never forward or to itself
  defp reject_targets(steps) do
    positions = steps |> Enum.with_index() |> Map.new(fn {s, i} -> {s.id, i} end)

    steps
    |> Enum.filter(& &1.on_reject)
    |> Enum.flat_map(fn step ->
      case Map.fetch(positions, step.on_reject) do
        :error ->
          ["step #{step.id}: on_reject names no step #{step.on_reject}"]

        {:ok, target} ->
          if target < Map.fetch!(positions, step.id),
            do: [],
            else: ["step #{step.id}: on_reject must point to an earlier step"]
      end
    end)
  end

  # -- Body ---------------------------------------------------------------------

  defp sections(body) do
    {sections, current} =
      body
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {done, current} ->
        case heading(line) do
          nil ->
            case current do
              nil -> {done, nil}
              {h, lines} -> {done, {h, [line | lines]}}
            end

          h ->
            {push(done, current), {h, []}}
        end
      end)

    push(sections, current)
    |> Enum.reverse()
    |> Enum.map(fn {h, lines} ->
      {h, lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()}
    end)
  end

  defp push(done, nil), do: done
  defp push(done, section), do: [section | done]

  # "## sign-off" -> "sign-off"; only level-two headings mark step sections
  defp heading(line) do
    case Regex.run(~r/\A##[ \t]+(.+?)[ \t]*#*[ \t]*\z/, line) do
      [_, text] -> String.trim(text)
      nil -> nil
    end
  end

  defp section_warnings(%__MODULE__{steps: steps, body: body}) do
    ids = MapSet.new(steps, & &1.id)

    body
    |> sections()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&MapSet.member?(ids, &1))
    |> Enum.map(&"section \"## #{&1}\" matches no step id")
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_), do: nil

  defp strip_at(nil), do: nil
  defp strip_at(value), do: String.trim_leading(value, "@")
end
