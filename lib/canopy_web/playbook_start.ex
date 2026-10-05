defmodule CanopyWeb.PlaybookStart do
  @moduledoc """
  The data behind the start form (`CanopyWeb.PlaybookComponents.start_form/1`),
  for the channel's run panel and the Playbooks page: the defaults that
  follow the chosen playbook and channel, and starting a run from the
  submitted params. A run the user starts has them as its starter, and its
  coordinator's wake resets the chatter budget.
  """

  import Phoenix.Component, only: [to_form: 2]

  alias Canopy.{Agents, Channels, Playbooks}
  alias Canopy.Playbooks.Runs

  @doc """
  The form for `params` (string keys: `playbook_id`, `channel_id`,
  `coordinator_id`, `brief`, `assign`). `channel` is the fixed channel (the
  run panel) or nil (the Playbooks page). The coordinator defaults to the
  playbook's `coordinator`, else the channel's owner.
  """
  def form(params, playbooks, channel \\ nil) do
    playbook =
      Enum.find(playbooks, &(&1.id == params["playbook_id"])) || List.first(playbooks)

    channel = channel || (present?(params["channel_id"]) && Channels.get(params["channel_id"]))
    definition = playbook && definition(playbook)

    coordinator_id =
      if present?(params["coordinator_id"]),
        do: params["coordinator_id"],
        else: definition && default_coordinator_id(definition, channel)

    to_form(
      %{
        "playbook_id" => playbook && playbook.id,
        "channel_id" => (channel && channel.id) || params["channel_id"],
        "coordinator_id" => coordinator_id,
        "brief" => params["brief"] || "",
        "assign" => params["assign"] || "",
        "inputs" => definition && definition.inputs,
        "hint" => hint(definition, channel)
      },
      as: :start,
      id: "start-playbook-form"
    )
  end

  @doc """
  Starts the run the form describes. `{:ok, run}` or `{:error, reason}`.

  From the Start page, `runs_in: "new"` runs it in a new channel on
  `repository_id`, named `channel_name` when given (Canopy picks a free name
  otherwise), and `roles` (`%{role => agent name}`) overrides the roster
  where it differs from who would fill the role anyway.
  """
  def start(params, channel \\ nil)

  def start(%{"runs_in" => "new"} = params, nil) do
    case present?(params["repository_id"]) &&
           Enum.find(Canopy.Repositories.list(), &(&1.id == params["repository_id"])) do
      %{} = repository ->
        # a name is always given, so the run gets a new channel even when the
        # playbook itself runs where it's started
        name =
          blank_to_nil(params["channel_name"]) ||
            channel_name(playbook_name(params["playbook_id"]), params["brief"], repository.id)

        params
        |> Map.delete("runs_in")
        |> Map.put("channel_name", name)
        |> do_start(%Canopy.Channels.Channel{repository_id: repository.id})

      _ ->
        {:error, "pick a repository"}
    end
  end

  def start(params, channel) do
    channel = channel || (present?(params["channel_id"]) && Channels.get(params["channel_id"]))
    do_start(params, channel && Channels.get!(channel.id))
  end

  defp do_start(params, channel) do
    with {:playbook, %{} = playbook} <- {:playbook, Playbooks.get(params["playbook_id"] || "")},
         {:channel, %{} = channel} <- {:channel, channel},
         {:coordinator, %{} = coordinator} <-
           {:coordinator, Agents.get(params["coordinator_id"] || "")},
         :ok <- roles_filled(params, playbook),
         {:ok, run, _new?} <-
           Runs.start(%{
             playbook: playbook,
             channel: channel,
             channel_name: params["channel_name"],
             coordinator: coordinator,
             started_by_agent_id: nil,
             brief: params["brief"],
             assign: assign(params, playbook)
           }) do
      {:ok, run}
    else
      {:playbook, _} -> {:error, "pick a playbook"}
      {:channel, _} -> {:error, "pick a channel"}
      {:coordinator, _} -> {:error, "pick a lead"}
      {:error, reason} -> {:error, reason}
    end
  end

  # role overrides: the free-text `assign` (the run panel), or the Start
  # page's role selects where they differ from who fills the role anyway
  defp assign(%{"roles" => %{} = roles}, playbook) do
    defaults =
      case definition(playbook) do
        nil -> %{}
        definition -> Map.new(roster_rows(definition), &{&1.role, &1.agent && &1.agent.name})
      end

    roles
    |> Enum.reject(fn {role, name} -> name in [nil, ""] or Map.get(defaults, role) == name end)
    |> Map.new()
  end

  defp assign(params, _playbook), do: params["assign"]

  # the Start page names every role; one nobody fills is said here, in its
  # words, before `Runs.start` refuses it in its own
  defp roles_filled(%{"roles" => %{} = roles}, playbook) do
    rows =
      case definition(playbook) do
        nil -> []
        definition -> roster_rows(definition)
      end

    unfilled =
      for row <- rows,
          is_nil(row.agent) and Map.get(roles, row.role) in [nil, ""],
          do: CanopyWeb.PlaybookBuilder.humanize(row.role)

    case unfilled do
      [] -> :ok
      roles -> {:error, "pick who does #{Enum.join(roles, ", ")}"}
    end
  end

  defp roles_filled(_params, _playbook), do: :ok

  @doc """
  Who fills each role of a definition when a run starts, the way
  `Runs.resolve_roster/3` decides it: `[%{role, agent, source}]`, where
  `source` says why ("from @team", "playbook default") and `agent` is nil
  when nobody does.
  """
  def roster_rows(definition) do
    team = definition.team && Canopy.Teams.get_by_name(definition.team)
    members = if team, do: Canopy.Teams.active_members(team), else: []
    labels = if team, do: Canopy.Teams.member_roles(team), else: %{}

    definition
    |> Canopy.Playbooks.Definition.owner_roles()
    |> Enum.map(fn role ->
      cond do
        agent = Enum.find(members, &(labels[&1.id] == role)) ->
          %{role: role, agent: agent, source: "from @#{team.name}"}

        agent = Enum.find(members, &(&1.name == role)) ->
          %{role: role, agent: agent, source: "from @#{team.name}"}

        name = definition.roles[role] ->
          case Agents.get_by_name(name) do
            %{active: true} = agent -> %{role: role, agent: agent, source: "playbook default"}
            _ -> %{role: role, agent: nil, source: "@#{name} isn't available"}
          end

        true ->
          %{role: role, agent: nil, source: "nobody fills it yet"}
      end
    end)
  end

  @doc "The channel name a new run's channel gets unless one is given: the playbook plus the brief's first words."
  def channel_name(playbook_name, brief, repository_id) do
    words =
      (brief || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, " ")
      |> String.split()
      |> Enum.take(4)

    base = [playbook_name | words] |> Enum.join("-") |> String.slice(0, 50) |> String.trim("-")

    if repository_id do
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn
        1 -> base
        n -> "#{base}-#{n}"
      end)
      |> Enum.find(&is_nil(Channels.get_by_name(repository_id, &1)))
    else
      base
    end
  end

  defp playbook_name(id) do
    case present?(id) && Playbooks.get(id) do
      %{name: name} -> name
      _ -> "run"
    end
  end

  defp blank_to_nil(value) do
    if present?(value) and String.trim(value) != "", do: String.trim(value), else: nil
  end

  defp definition(playbook) do
    case Playbooks.definition(playbook) do
      {:ok, definition} -> definition
      {:error, _} -> nil
    end
  end

  defp default_coordinator_id(definition, channel) do
    case Runs.default_coordinator(definition, channel || nil) do
      %{id: id} -> id
      nil -> nil
    end
  end

  defp hint(nil, _channel), do: nil

  defp hint(definition, channel) do
    where =
      cond do
        definition.channel == "new" and channel ->
          "Runs in a new channel on #{channel_repository(channel)}, owned by the lead."

        definition.channel == "new" ->
          "Runs in a new channel on the chosen channel's repository, owned by the lead."

        true ->
          "Runs in this channel."
      end

    team = if definition.team, do: " @#{definition.team} joins it.", else: ""
    where <> team
  end

  defp channel_repository(channel) do
    case Canopy.Repo.preload(channel, :repository).repository do
      %{name: name} -> name
      _ -> "its repository"
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
