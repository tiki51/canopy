defmodule Canopy.Templates.TeamTemplate do
  @moduledoc """
  A team as a file inside a bundle (`teams/<name>.md`): frontmatter only
  (`canopy_template: 1`, `kind: team`, `name`, `display_name`,
  `description`, `lead`, and `members`, each a `name` with an optional
  `role` label); a body is allowed and ignored. Members and the lead are
  agent names, resolved on import to agents in the same bundle first, then
  to agents already here.
  """

  alias Canopy.Frontmatter
  alias Canopy.Templates.AgentTemplate
  alias Canopy.Teams.Team

  @known_keys ~w(canopy_template kind name display_name description lead members exported_from)
  @max_members 100

  defstruct name: nil, display_name: nil, description: nil, lead: nil, members: [], warnings: []

  @type member :: %{name: String.t(), role: String.t() | nil}
  @type t :: %__MODULE__{members: [member()]}

  @doc "The team as a file. `roles` is `%{agent_id => role}` (`Teams.member_roles/1`)."
  def encode(%Team{} = team, roles \\ %{}) do
    members =
      team.members
      |> Enum.sort_by(&{&1.id != team.lead_agent_id, &1.name})
      |> Enum.map(&[name: &1.name, role: Map.get(roles, &1.id)])

    Frontmatter.document(
      [
        canopy_template: AgentTemplate.version(),
        kind: "team",
        name: team.name,
        display_name: team.display_name,
        description: team.description,
        lead: team.lead && team.lead.name,
        members: members,
        exported_from: Canopy.Templates.exported_from()
      ],
      nil
    )
  end

  @doc "Builds the team from already-read frontmatter: `{:ok, t}` or `{:error, lines}`."
  def from_fields(data) do
    {members, member_errors} = members(data["members"])

    errors =
      Enum.flat_map(~w(name display_name description lead), fn key ->
        case Map.get(data, key) do
          nil -> []
          value when is_binary(value) -> []
          _ -> ["#{key} must be text"]
        end
      end) ++
        if(blank?(data["name"]), do: ["name is missing"], else: []) ++
        if(blank?(data["lead"]), do: ["lead is missing: every team has a lead"], else: []) ++
        member_errors

    lead = strip(data["lead"])

    errors =
      if errors == [] and lead not in Enum.map(members, & &1.name),
        do: errors ++ ["the lead @#{lead} must be one of the members"],
        else: errors

    if errors == [] do
      {:ok,
       %__MODULE__{
         name: strip(data["name"]),
         display_name: trimmed(data["display_name"]),
         description: trimmed(data["description"]),
         lead: lead,
         members: members,
         warnings:
           (Map.keys(data) -- @known_keys)
           |> Enum.sort()
           |> Enum.map(&"unknown field #{inspect(&1)}; ignored")
       }}
    else
      {:error, errors}
    end
  end

  defp members(list) when is_list(list) and list != [] and length(list) <= @max_members do
    {members, errors} =
      list
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn
        {%{"name" => name} = member, n}, errors when is_binary(name) ->
          role = member["role"]

          cond do
            blank?(name) ->
              {nil, errors ++ ["member #{n}: name is missing"]}

            not (is_nil(role) or is_binary(role)) ->
              {nil, errors ++ ["member #{n}: role must be text"]}

            true ->
              {%{name: strip(name), role: trimmed(role)}, errors}
          end

        {name, _n}, errors when is_binary(name) and name != "" ->
          {%{name: strip(name), role: nil}, errors}

        {_other, n}, errors ->
          {nil, errors ++ ["member #{n}: must be a name, or a name and a role"]}
      end)

    {members |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.name), errors}
  end

  defp members(list) when is_list(list) and length(list) > @max_members,
    do: {[], ["at most #{@max_members} members"]}

  defp members(_), do: {[], ["members must list at least one agent"]}

  defp strip(value) when is_binary(value),
    do: value |> String.trim() |> String.trim_leading("@") |> String.downcase()

  defp strip(_), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_), do: nil

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
