defmodule Canopy.Seeds do
  @moduledoc "Creates Canopy's initial settings, user, default agents, starter team, and starter playbook."

  alias Canopy.{Agents, Settings, Teams, Users}

  @doc "Seeds missing defaults without changing existing records."
  def run do
    settings = Settings.get()
    user = Users.local()

    IO.puts("settings: opencode_url=#{settings.opencode_url}")
    IO.puts("user: #{user.display_name} (#{user.id})")

    for attrs <- starter_agents() do
      case Agents.get_by_name(attrs.name) do
        nil ->
          {:ok, agent} = Agents.create(attrs)
          IO.puts("created agent @#{agent.name}")

        agent ->
          IO.puts("agent @#{agent.name} already exists")
      end
    end

    seed_teams()

    # Starter playbooks, created when missing by name; an existing one is never edited.
    for result <- Canopy.Playbooks.seed() do
      case result do
        {:created, name} -> IO.puts("created playbook #{name}")
        {:exists, name} -> IO.puts("playbook #{name} already exists")
      end
    end

    # The cost auditor answers "Request audit" on the Costs page.
    case {Canopy.Costs.Auditor.agent(), Agents.get_by_name("finops")} do
      {nil, %{id: id}} ->
        {:ok, _} = Canopy.Costs.Auditor.assign(id)
        IO.puts("assigned @finops as the cost auditor")

      _ ->
        :ok
    end
  end

  # Created when missing, from whichever of its agents exist; an existing team
  # is never edited.
  defp seed_teams do
    for %{name: name, members: names, lead: lead} = attrs <- starter_teams() do
      agents = Enum.flat_map(names, &List.wrap(Agents.get_by_name(&1)))
      lead = Enum.find(agents, &(&1.name == lead)) || List.first(agents)

      cond do
        Teams.get_by_name(name) ->
          IO.puts("team @#{name} already exists")

        Agents.get_by_name(name) || is_nil(lead) ->
          IO.puts("skipped team @#{name}")

        true ->
          {:ok, team} =
            attrs
            |> Map.drop([:members, :lead])
            |> Map.merge(%{agent_ids: Enum.map(agents, & &1.id), lead_agent_id: lead.id})
            |> Teams.create()

          IO.puts("created team @#{team.name}")
      end
    end
  end

  defp starter_teams do
    [
      %{
        name: "bugfix-team",
        display_name: "Bugfix team",
        description: "Reproduces, fixes, tests, and reviews bugs",
        # the implementation engineer owns the fix, so it owns the team's channels
        lead: "backend",
        members: ~w(frontend backend test reviewer)
      }
    ]
  end

  @doc "The names of the starter agents."
  def agent_names, do: Enum.map(starter_agents(), & &1.name)

  # The 13 starter agents are gallery templates marked `seed: true`
  # (priv/templates/agents), so the gallery can re-add one that was changed or
  # retired. They get no engine and no model of their own: they follow the
  # default engine and its default model from Settings. Their `mode` sets
  # both engines' reach (OpenCode's agent, Claude Code's permission mode), so
  # a `plan` starter is read-only whichever engine is the default.
  defp starter_agents do
    for template <- Canopy.Templates.Gallery.seed_agents() do
      {attrs, _notices} = Canopy.Templates.AgentTemplate.attrs(template, "opencode")

      attrs
      |> Map.take([
        :name,
        :display_name,
        :role,
        :group,
        :color,
        :system_prompt,
        :opencode_agent,
        :permission_mode
      ])
      |> Map.put(:engine, nil)
    end
  end
end
