defmodule Canopy.Templates do
  @moduledoc """
  Agents, teams and playbooks as files, to share between machines: one agent
  is a Markdown file with YAML frontmatter (`Canopy.Templates.AgentTemplate`),
  several things are a zip of such files (`Canopy.Templates.Bundle`), and
  `Canopy.Templates.Import` previews and applies a file. Canopy ships a few
  starter agents and a bundle as templates (`Canopy.Templates.Gallery`).

  Only the user exports and imports: there are no MCP tools for it, since
  importing an agent is a privilege change. Nothing secret is exported, and
  an agent's memory only when the user asks.
  """

  alias Canopy.{Frontmatter, Memory, Playbooks, Teams}
  alias Canopy.Playbooks.Playbook
  alias Canopy.Teams.Team
  alias Canopy.Templates.{AgentTemplate, Bundle, TeamTemplate}

  @doc "What a file says made it: `Canopy <version>`. Informational; never read back."
  def exported_from, do: "Canopy #{Application.spec(:canopy, :vsn)}"

  # -- Export -------------------------------------------------------------------

  @doc "One agent as `{filename, text}`; `memory: true` adds its memory."
  def export_agent(agent, opts \\ []) do
    {"#{agent.name}.md", AgentTemplate.encode(agent, memory: memory_for(agent, opts))}
  end

  @doc "Several agents as a bundle zip, `{filename, bytes}`."
  def export_agents(agents, opts \\ []) do
    files = Enum.map(agents, &agent_entry(&1, opts))

    manifest = %{
      name: "canopy-agents",
      description: "#{length(agents)} #{if length(agents) == 1, do: "agent", else: "agents"}"
    }

    {"canopy-agents.zip", Bundle.encode(manifest, files)}
  end

  @doc """
  A team as a bundle zip, `{filename, bytes}`: the team file and its member
  agents; `playbooks: true` adds the playbooks whose `team:` is this team,
  `memory: true` the members' memory.
  """
  def export_team(%Team{} = team, opts \\ []) do
    team = Teams.get!(team.id)
    roles = Teams.member_roles(team)

    playbooks =
      if Keyword.get(opts, :playbooks), do: team_playbooks(team), else: []

    files =
      Enum.map(team.members, &agent_entry(&1, opts)) ++
        [{"teams/#{team.name}.md", TeamTemplate.encode(team, roles)}] ++
        Enum.map(playbooks, &{"playbooks/#{&1.name}.md", &1.body})

    manifest = %{
      name: team.name,
      description: team.description || team.display_name,
      readme: readme(team, playbooks)
    }

    {"#{team.name}.canopy.zip", Bundle.encode(manifest, files)}
  end

  @doc "A playbook as `{filename, text}`: its stored text, verbatim."
  def export_playbook(%Playbook{} = playbook), do: {"#{playbook.name}.md", playbook.body}

  @doc "The playbooks whose `team:` names this team."
  def team_playbooks(%Team{name: name}) do
    Playbooks.list()
    |> Enum.filter(fn playbook ->
      case Playbooks.definition(playbook) do
        {:ok, %{team: ^name}} -> true
        _ -> false
      end
    end)
  end

  defp agent_entry(agent, opts) do
    {"agents/#{agent.name}.md", AgentTemplate.encode(agent, memory: memory_for(agent, opts))}
  end

  defp memory_for(agent, opts),
    do: if(Keyword.get(opts, :memory), do: Memory.get(agent.id))

  defp readme(team, playbooks) do
    playbook_line =
      case playbooks do
        [] -> ""
        list -> "\n\nPlaybooks: " <> Enum.map_join(list, ", ", & &1.name) <> "."
      end

    "# #{team.display_name}\n\nThe @#{team.name} team and its members, exported from Canopy." <>
      playbook_line <> "\nImport it from Agents → Import."
  end

  # -- Reading ------------------------------------------------------------------

  @doc """
  Reads one Markdown file of any kind:

    * `{:ok, :agent, %AgentTemplate{}}` (a Canopy agent template, or a
      Claude Code subagent file)
    * `{:ok, :team, %TeamTemplate{}}`
    * `{:ok, :playbook, text}` (a playbook keeps its own format: no
      `canopy_template`, and `steps`)
    * `{:error, lines}`

  A file claiming `kind: bundle` is a bundle's `canopy.md`, not something
  to import on its own. `gallery: true` is for Canopy's own gallery files.
  """
  def decode(text, opts \\ []) when is_binary(text) do
    with {:ok, data, body} <-
           Frontmatter.read(
             text,
             "the file",
             AgentTemplate.max_bytes(),
             AgentTemplate.max_header_bytes()
           ) do
      cond do
        Map.has_key?(data, "canopy_template") ->
          with :ok <- AgentTemplate.check_version(data) do
            case data["kind"] do
              "agent" ->
                with {:ok, t} <- AgentTemplate.from_fields(data, body, opts), do: {:ok, :agent, t}

              "team" ->
                with {:ok, t} <- TeamTemplate.from_fields(data), do: {:ok, :team, t}

              "bundle" ->
                {:error, ["that's a bundle's canopy.md; import the whole .zip instead"]}

              nil ->
                {:error, ["kind is missing (agent, team or bundle)"]}

              other ->
                {:error,
                 ["kind #{inspect(other)} isn't one this Canopy knows (agent, team or bundle)"]}
            end
          end

        Map.has_key?(data, "steps") ->
          {:ok, :playbook, text}

        Map.has_key?(data, "name") and Map.has_key?(data, "description") ->
          with {:ok, t} <- AgentTemplate.from_claude_code(data, body), do: {:ok, :agent, t}

        true ->
          {:error, ["canopy_template is missing: this isn't a Canopy template"]}
      end
    end
  end
end
