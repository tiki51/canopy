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

  @new_section CanopyWeb.SectionPicker.new()

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
        "hint" => hint(definition)
      },
      as: :start,
      id: "start-playbook-form"
    )
  end

  @doc """
  Starts the run the form describes. `{:ok, run}` or `{:error, reason}`.

  From the Start page (`channel` nil), `runs_in: "new"` runs it in a new
  channel on `repository_id`, named `channel_name` when given (Canopy picks a
  free name otherwise); any other `runs_in` (`"existing"`, or the older
  `"current"`) runs it in `channel_id`. A channel with a run in progress is
  refused, and a DM or archived one counts as none picked. A typed name
  that's taken, archived channels included, is refused. `roles` (`%{role => agent name}`) overrides the roster where it
  differs from who would fill the role anyway. The new channel's sidebar
  section is `section` (a name, `""` for none, `CanopyWeb.SectionPicker.new/0` for the name in
  `section_new`), which overrides the playbook's `section:`; left out, the
  playbook's applies.

  From the run panel, the run always happens in `channel`.

  `document_ids` (optional) are files already stored, in order: they post
  with the brief as the run's kickoff message (see `Canopy.Playbooks.Runs.start/1`).
  The page stores uploads before it calls this; nothing here deletes them.
  """
  def start(params, channel \\ nil)

  def start(%{"runs_in" => "new"} = params, nil) do
    case present?(params["repository_id"]) &&
           Enum.find(Canopy.Repositories.list(), &(&1.id == params["repository_id"])) do
      %{} = repository ->
        # a name is always given, so `Runs.start` makes a new channel; a typed
        # one is normalised the way `Runs` does before it is looked up
        name =
          Runs.channel_name(
            repository.id,
            blank_to_nil(params["channel_name"]),
            playbook_name(params["playbook_id"]),
            params["brief"]
          )

        cond do
          Channels.get_by_name(repository.id, name) ->
            {:error,
             "##{name} already exists in #{repository.name}; pick another name, or choose Existing channel"}

          section(params) == :blank ->
            {:error, "name the new section"}

          true ->
            params
            |> Map.delete("runs_in")
            |> Map.put("channel_name", name)
            |> Map.put("section", section(params))
            |> do_start(%Canopy.Channels.Channel{repository_id: repository.id})
        end

      _ ->
        {:error, "pick a repository"}
    end
  end

  def start(params, nil) do
    # only what `channel_groups/0` offers: a DM or an archived channel is
    # treated as no channel at all
    channel =
      with true <- present?(params["channel_id"]),
           %{} = channel <- Channels.get(params["channel_id"]),
           false <- Channels.dm?(channel) or Channels.archived?(channel) do
        channel
      else
        _ -> nil
      end

    # said in the page's words before `Runs.start`, which stays the race-safe check
    case channel && Runs.active_for_channel(channel.id) do
      %{playbook_name: playbook} ->
        {:error,
         "##{channel.name} already has a run in progress (#{playbook}); pick another channel or start a new one"}

      _ ->
        params |> Map.drop(["channel_name", "section"]) |> do_start(channel)
    end
  end

  # the run panel: never a new channel, whatever the post says
  def start(params, %Canopy.Channels.Channel{} = channel) do
    params
    |> Map.drop(["channel_name", "section"])
    |> do_start(Channels.get!(channel.id), "from the Playbooks page")
  end

  @doc """
  The Start page's existing channels, `[{repository name, [%{id, name,
  run_active?}]}]`: open channels (no DMs), repositories and channels by
  name, no repository without one. `run_active?` is a run in progress
  (active or awaiting approval), which the page shows but can't pick.
  """
  def channel_groups do
    live = Runs.live_by_channel()

    channels =
      Channels.list()
      |> Enum.reject(&(Channels.dm?(&1) or Channels.archived?(&1)))
      |> Enum.group_by(& &1.repository_id)

    for repository <- Canopy.Repositories.list(),
        list = Map.get(channels, repository.id, []),
        list != [] do
      {repository.name,
       Enum.map(list, &%{id: &1.id, name: &1.name, run_active?: Map.has_key?(live, &1.id)})}
    end
  end

  # `via`: how this page's user opens a new channel instead, for the refusals
  defp do_start(params, channel, via \\ "by choosing New channel") do
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
             section: params["section"],
             coordinator: coordinator,
             started_by_agent_id: nil,
             brief: params["brief"],
             document_ids: document_ids(params["document_ids"]),
             assign: assign(params, playbook),
             new_channel_via: via
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
        nil ->
          %{}

        definition ->
          Map.new(Runs.roster_preview(definition), &{&1.role, &1.agent && &1.agent.name})
      end

    roles
    |> Enum.reject(fn {role, name} -> name in [nil, ""] or Map.get(defaults, role) == name end)
    |> Map.new()
  end

  defp assign(params, _playbook), do: params["assign"]

  # the brief's files, already stored: a list of ids, anything else is none
  defp document_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp document_ids(_ids), do: []

  # the Start page names every role; one nobody fills is said here, in its
  # words, before `Runs.start` refuses it in its own
  defp roles_filled(%{"roles" => %{} = roles}, playbook) do
    rows =
      case definition(playbook) do
        nil -> []
        definition -> Runs.roster_preview(definition)
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

  # The Start page's section picker, as `Runs.start` takes it: a name, `""`
  # for "No section" (not nil, which would mean the playbook's default), or
  # nil when the form had no picker. `:blank` is "New section…" left empty.
  defp section(%{"section" => @new_section} = params) do
    case blank_to_nil(params["section_new"]) do
      nil -> :blank
      name -> name
    end
  end

  defp section(%{"section" => name}) when is_binary(name), do: String.trim(name)
  defp section(_params), do: nil

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

  # the run panel's line: a run started there always runs there
  defp hint(nil), do: nil

  defp hint(definition) do
    team = if definition.team, do: " @#{definition.team} joins it.", else: ""
    "Runs in this channel." <> team
  end

  defp present?(value), do: is_binary(value) and value != ""
end
