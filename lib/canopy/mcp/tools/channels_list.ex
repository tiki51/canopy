defmodule Canopy.MCP.Tools.ChannelsList do
  @moduledoc """
  List the Canopy channels you belong to, with owner, task status and sidebar
  section. Your current channel is marked. Ends with each project's sections,
  so a new channel can be filed under an existing one.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.Channels
  alias Canopy.Channels.{Section, Sections}
  alias Canopy.MCP.{Format, Tool}

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, _params ->
      channels =
        Channels.list()
        |> Enum.filter(fn channel -> Enum.any?(channel.agents, &(&1.id == ctx.agent.id)) end)

      lines = Enum.map(channels, &line(&1, ctx))

      case lines do
        [] -> {:ok, "You are not a member of any channel."}
        lines -> {:ok, Enum.join(lines ++ sections(channels), "\n")}
      end
    end)
  end

  defp line(channel, ctx) do
    markers =
      [
        channel.id == ctx.channel.id && "current",
        Channels.dm?(channel) && "dm with the user",
        channel.status == "archived" && "archived"
      ]
      |> Enum.filter(& &1)

    marker = if markers == [], do: "", else: " (" <> Enum.join(markers, ", ") <> ")"

    task =
      case channel.task do
        nil -> "none"
        task -> "#{task.status} — #{task.title}"
      end

    section =
      case channel.section do
        %Section{name: name} -> ", section #{name}"
        _ -> ""
      end

    "##{channel.name} [#{channel.id}]#{marker} in #{channel.repository.name}: " <>
      "owner #{Format.agent_ref(channel.owner)}, task #{task}#{section}"
  end

  # One line per project you have a channel in: its sections, by position.
  defp sections(channels) do
    repositories =
      channels
      |> Enum.reject(&Channels.dm?/1)
      |> Enum.map(& &1.repository)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.name)

    lines =
      Enum.map(repositories, fn repository ->
        names =
          case Sections.list(repository.id) do
            [] -> "none yet"
            sections -> Enum.map_join(sections, ", ", & &1.name)
          end

        "Sections in #{repository.name}: #{names}"
      end)

    if lines == [], do: [], else: ["" | lines]
  end
end
