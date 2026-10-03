defmodule Canopy.Templates.Gallery do
  @moduledoc """
  The starter templates Canopy ships, read at compile time from
  `priv/templates/` so a release can't miss them:

    * `agents/*.md` — agent templates. They leave out `engine`, `model` and
      `effort`, so an import follows this machine's engine and default
      model; `mode` says whether the agent edits. The ones marked
      `seed: true` (a gallery-only key that exports never write) are also
      what `Canopy.Seeds` creates on a fresh install.
    * `bundles/<name>/` — a bundle as an unzipped folder (`canopy.md`,
      `teams/`, `playbooks/`). Agents its team or playbooks name that the
      folder doesn't hold come from the agent templates above, so each
      starter prompt has one source.

  `gallery_test.exs` decodes every file, so a broken one fails the build.
  """

  alias Canopy.Agents.Agent
  alias Canopy.Templates
  alias Canopy.Templates.{AgentTemplate, TeamTemplate}

  @root Application.app_dir(:canopy, "priv/templates")
  @agent_paths Path.wildcard(Path.join(@root, "agents/*.md")) |> Enum.sort()
  @bundle_paths Path.wildcard(Path.join(@root, "bundles/*/**/*.md")) |> Enum.sort()

  for path <- @agent_paths ++ @bundle_paths, do: @external_resource(path)

  @agents Enum.map(@agent_paths, &{Path.basename(&1, ".md"), File.read!(&1)})

  @bundles @bundle_paths
           |> Enum.group_by(fn path ->
             path |> Path.relative_to(Path.join(@root, "bundles")) |> Path.split() |> hd()
           end)
           |> Enum.map(fn {name, paths} ->
             dir = Path.join([@root, "bundles", name])
             {name, Enum.map(paths, &{Path.relative_to(&1, dir), File.read!(&1)})}
           end)
           |> Enum.sort()

  @paths_hash :erlang.md5(:erlang.term_to_binary(@agent_paths ++ @bundle_paths))

  # a file added to or removed from priv/templates recompiles this module
  def __mix_recompile__? do
    paths =
      Enum.sort(Path.wildcard(Path.join(@root, "agents/*.md"))) ++
        Enum.sort(Path.wildcard(Path.join(@root, "bundles/*/**/*.md")))

    :erlang.md5(:erlang.term_to_binary(paths)) != @paths_hash
  end

  @doc "Every gallery agent as `%{name, text, template}`, by name."
  def agents do
    for {name, text} <- @agents do
      {:ok, :agent, template} = Templates.decode(text, gallery: true)
      %{name: name, text: text, template: template}
    end
  end

  @doc "The raw `{file name, text}` of the agent files, for the gallery test."
  def agent_files, do: @agents

  @doc "One gallery agent's file text, or nil."
  def agent_text(name) do
    case List.keyfind(@agents, name, 0) do
      {_, text} -> text
      nil -> nil
    end
  end

  @doc "The seeded agents' templates (`seed: true`), by name."
  def seed_agents, do: agents() |> Enum.filter(& &1.template.seed) |> Enum.map(& &1.template)

  @doc "Every gallery bundle as `%{name, title, description, files}`."
  def bundles do
    for {name, _} <- @bundles, do: bundle(name)
  end

  @doc """
  One gallery bundle as `%{name, title, description, files}` (`files` as
  `[{path, text}]`, with the agents it needs from the agent templates), or nil.
  """
  def bundle(name) do
    with {_, files} <- List.keyfind(@bundles, name, 0) do
      manifest =
        case List.keyfind(files, "canopy.md", 0) do
          {_, text} ->
            {:ok, data, _body} =
              Canopy.Frontmatter.read(
                text,
                "canopy.md",
                AgentTemplate.max_bytes(),
                AgentTemplate.max_header_bytes()
              )

            data

          nil ->
            %{}
        end

      %{
        name: name,
        title: manifest["display_name"] || manifest["name"] || name,
        description: manifest["description"],
        files: files ++ needed_agents(files)
      }
    end
  end

  # Agents named by the bundle's teams and playbooks but not in its folder.
  defp needed_agents(files) do
    present =
      for {"agents/" <> file, _} <- files, into: MapSet.new(), do: Path.basename(file, ".md")

    files
    |> Enum.flat_map(fn
      {"teams/" <> _, text} ->
        case Templates.decode(text) do
          {:ok, :team, %TeamTemplate{members: members}} -> Enum.map(members, & &1.name)
          _ -> []
        end

      {"playbooks/" <> _, text} ->
        case Canopy.Playbooks.Definition.parse(text) do
          {:ok, d} -> Enum.reject([d.coordinator | Map.values(d.roles)], &is_nil/1)
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.flat_map(fn name ->
      case agent_text(name) do
        nil -> []
        text -> [{"agents/#{name}.md", text}]
      end
    end)
  end

  @doc """
  How a gallery agent compares with an agent of the same name here:
  `:added` when the engine-neutral parts match (names, role, group, colour,
  prompt, and whether it edits), `:differs` otherwise. Engine and model are
  this machine's business, so they never count.
  """
  def compare(%AgentTemplate{} = template, %Agent{} = agent) do
    same? =
      norm(template.display_name || template.name) == norm(agent.display_name) and
        norm(template.role) == norm(agent.role) and
        norm(template.group) == norm(agent.group) and
        norm(template.color) == norm(agent.color) and
        norm(template.system_prompt) == norm(agent.system_prompt) and
        (template.mode || "build") == to_string(Agent.execution_mode(agent) || "build")

    if same?, do: :added, else: :differs
  end

  defp norm(nil), do: nil

  defp norm(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
