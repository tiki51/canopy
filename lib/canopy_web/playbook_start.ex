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

  @doc "Starts the run the form describes. `{:ok, run}` or `{:error, reason}`."
  def start(params, channel \\ nil) do
    channel = channel || (present?(params["channel_id"]) && Channels.get(params["channel_id"]))

    with {:playbook, %{} = playbook} <- {:playbook, Playbooks.get(params["playbook_id"] || "")},
         {:channel, %{} = channel} <- {:channel, channel},
         {:coordinator, %{} = coordinator} <-
           {:coordinator, Agents.get(params["coordinator_id"] || "")},
         {:ok, run, _new?} <-
           Runs.start(%{
             playbook: playbook,
             channel: Channels.get!(channel.id),
             coordinator: coordinator,
             started_by_agent_id: nil,
             brief: params["brief"],
             assign: params["assign"]
           }) do
      {:ok, run}
    else
      {:playbook, _} -> {:error, "pick a playbook"}
      {:channel, _} -> {:error, "pick a channel"}
      {:coordinator, _} -> {:error, "pick a coordinator"}
      {:error, reason} -> {:error, reason}
    end
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
          "Runs in a new channel on #{channel_repository(channel)}, owned by the coordinator."

        definition.channel == "new" ->
          "Runs in a new channel on the chosen channel's repository, owned by the coordinator."

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
