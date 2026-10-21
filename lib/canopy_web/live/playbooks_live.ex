defmodule CanopyWeb.PlaybooksLive do
  @moduledoc """
  The playbook library, in three pages under one LiveView (the builder is
  `CanopyWeb.PlaybookBuilderLive`; a playbook's export is a plain download
  from `CanopyWeb.TemplateController`):

    * `/playbooks` — a row per playbook, starred ones first, then the rest,
      then drafts (collapsed unless an agent's draft waits, or `?show=drafts`).
      A row opens in place to show its steps and where it runs; a filter
      narrows every section. Management sits in each row's ⋯ menu.
    * `/playbooks/new` — how to start: copy a playbook, start blank, or
      describe it to an agent, which drafts it (`CanopyWeb.PlaybookAsk`)
    * `/playbooks/:id/start` — start a run: the brief and its files, where it
      runs, who leads it and who does what, beside what will happen. Files
      are stored as documents before the start and post with the brief as
      the run's first message.

  Playbooks are global to Canopy. An enabled playbook is listed in every
  agent's system prompt, so a draft an agent saved stays disabled until the
  user enables it.
  """

  use CanopyWeb, :live_view

  import CanopyWeb.PlaybookComponents, only: [avatar: 1, playbook_row: 1]
  import CanopyWeb.AttachmentComponents, only: [file_chips: 1, library_picker: 1]

  alias Canopy.{Agents, Documents, Messages, Playbooks, Repositories, Users}
  alias Canopy.Channels.Sections
  alias Canopy.Playbooks.{Definition, Playbook, Runs, Writer}
  alias CanopyWeb.{Attachments, PlaybookAsk, PlaybookBuilder, PlaybookStart, SectionPicker}

  @new_section SectionPicker.new()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Playbooks.subscribe()
      Runs.subscribe()
    end

    active = Agents.list_active()

    {:ok,
     socket
     |> assign(:playbook, nil)
     |> assign(:active_agents, active)
     |> assign(:by_name, Map.new(active, &{&1.name, &1}))
     |> assign(:filter, "")
     |> assign(:open_id, nil)
     |> assign(:moved_id, nil)
     |> assign(:drafts_open?, false)
     |> assign(:brief_picked, [])
     |> assign(:consumed_refs, [])
     |> assign(:library, nil)
     |> allow_upload(:brief_files,
       accept: :any,
       max_entries: Messages.max_attachments(),
       max_file_size: Documents.max_bytes(),
       auto_upload: true
     )
     |> load_list()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case {socket.assigns.live_action, params} do
      {:index, _} ->
        # an agent's draft waiting for review opens Drafts; so does an old
        # `?show=drafts` link
        drafts_open? =
          params["show"] == "drafts" or
            Enum.any?(socket.assigns.playbooks, &agent_draft?/1)

        {:noreply,
         socket
         |> assign(:playbook, nil)
         |> assign(:drafts_open?, drafts_open?)
         |> assign(:page_title, "Playbooks")}

      {:new, _} ->
        agents = socket.assigns.active_agents

        {:noreply,
         socket
         |> assign(:page_title, "New playbook")
         |> assign(:copy_q, "")
         |> assign(
           :copy_id,
           socket.assigns |> copy_rows("") |> List.first() |> then(&(&1 && &1.id))
         )
         |> assign(:describe, "")
         |> assign(:drafter, lead_like(agents))}

      {:start, %{"id" => id}} ->
        case Playbooks.get(id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That playbook no longer exists.")
             |> push_navigate(to: ~p"/playbooks")}

          playbook ->
            {:noreply,
             socket
             |> assign(:playbook, playbook)
             |> assign(:page_title, "Start " <> playbook.name)
             |> assign_start_page()
             |> assign_start(%{})}
        end
    end
  end

  @impl true
  def handle_info({:playbooks, :changed}, socket), do: {:noreply, load_list(socket)}

  # only the changed channel's runs can have moved a playbook's last run
  def handle_info({:playbook_runs, :changed, channel_id}, socket) do
    {:noreply,
     socket
     |> assign(:active_runs, Playbooks.active_runs())
     |> update(:last_runs, fn last ->
       Map.merge(last, Playbooks.last_run_at(channel_id), fn _id, a, b -> later(a, b) end)
     end)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Library ---------------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(:filter, q) |> assign(:moved_id, nil)}

  def handle_event("clear_filter", _params, socket),
    do: {:noreply, socket |> assign(:filter, "") |> assign(:moved_id, nil)}

  def handle_event("expand", %{"id" => id}, socket) do
    open_id = if socket.assigns.open_id == id, do: nil, else: id
    {:noreply, socket |> assign(:open_id, open_id) |> assign(:moved_id, nil)}
  end

  def handle_event("toggle_drafts", _params, socket),
    do: {:noreply, socket |> update(:drafts_open?, &(!&1)) |> assign(:moved_id, nil)}

  # a filter that hides every draft would leave Review with nothing to show
  def handle_event("open_drafts", _params, socket),
    do: {:noreply, socket |> assign(drafts_open?: true, filter: "") |> assign(:moved_id, nil)}

  # Read again rather than trusting the page: the playbook may have been
  # disabled or deleted in another tab since.
  def handle_event("star", %{"id" => id}, socket) do
    result =
      case Playbooks.get(id) do
        nil -> {:error, "that playbook no longer exists"}
        playbook -> Playbooks.set_starred(playbook, is_nil(playbook.starred_at))
      end

    case result do
      {:ok, _playbook} ->
        {:noreply, socket |> load_list() |> assign(:moved_id, id)}

      {:error, reason} ->
        {:noreply,
         socket
         |> load_list()
         |> assign(:moved_id, nil)
         |> put_flash(:error, sentence(reason))}
    end
  end

  # The toggle carries the version on the page: enabling approves the text
  # the user saw, so a draft an agent replaced since is not enabled.
  def handle_event("toggle", %{"id" => id} = params, socket) do
    seen = params |> Map.get("version") |> parse_version()

    socket = assign(socket, :moved_id, nil)

    with %Playbook{} = playbook <- Playbooks.get(id),
         {:ok, playbook} <- Playbooks.set_enabled(playbook, not playbook.enabled, seen) do
      {:noreply,
       socket
       |> load_list()
       |> put_flash(
         :info,
         if(playbook.enabled,
           do: "Enabled #{playbook.name}: agents see it from their next turn.",
           else: "Disabled #{playbook.name}: agents no longer see it; runs in progress continue."
         )
       )}
    else
      {:error, :stale} ->
        {:noreply,
         socket
         |> load_list()
         |> put_flash(:error, "That playbook changed since the page loaded; read it again first.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "That playbook does not parse; fix it before enabling.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    with %Playbook{} = playbook <- Playbooks.get(id),
         {:ok, copy} <- Playbooks.duplicate(playbook) do
      {:noreply,
       socket
       |> put_flash(:info, "Copied to #{copy.name} (disabled until you enable it).")
       |> push_navigate(to: ~p"/playbooks/#{copy.id}/edit")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not copy that playbook.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    socket = assign(socket, :moved_id, nil)

    case Playbooks.get(id) do
      nil ->
        {:noreply, socket}

      playbook ->
        case Playbooks.delete(playbook) do
          {:ok, _} ->
            {:noreply, socket |> load_list() |> put_flash(:info, "Deleted #{playbook.name}.")}

          {:error, reason} when is_binary(reason) ->
            {:noreply, put_flash(socket, :error, String.capitalize(reason) <> ".")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete #{playbook.name}.")}
        end
    end
  end

  # -- New ---------------------------------------------------------------------------

  def handle_event("new_change", params, socket) do
    drafter =
      case params["drafter"] && Map.get(socket.assigns.by_name, params["drafter"]) do
        nil -> socket.assigns.drafter
        agent -> agent
      end

    {:noreply,
     socket
     |> assign(:copy_id, params["copy_id"] || socket.assigns.copy_id)
     |> assign(:copy_q, params["copy_q"] || socket.assigns.copy_q)
     |> assign(:describe, params["describe"] || socket.assigns.describe)
     |> assign(:drafter, drafter)}
  end

  # Enter in the copy filter submits the form; without a phx-submit the
  # browser would send it as a GET and reload the page.
  def handle_event("new_noop", _params, socket), do: {:noreply, socket}

  def handle_event("copy", _params, socket) do
    handle_event("duplicate", %{"id" => socket.assigns.copy_id || ""}, socket)
  end

  def handle_event("describe", params, socket) do
    socket = elem(handle_event("new_change", params, socket), 1)
    text = String.trim(socket.assigns.describe || "")

    cond do
      text == "" ->
        {:noreply, put_flash(socket, :error, "Say how the work should go first.")}

      is_nil(socket.assigns.drafter) ->
        {:noreply, put_flash(socket, :error, "There's no active agent to ask.")}

      true ->
        agent = socket.assigns.drafter

        case PlaybookAsk.ask(agent, PlaybookAsk.draft_request(text)) do
          {:ok, channel} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Asked @#{agent.name} to draft it. It shows up in Playbooks under Drafts for you to review."
             )
             |> push_navigate(to: ~p"/channels/#{channel.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
    end
  end

  # -- Start ---------------------------------------------------------------------------

  def handle_event("start_validate", %{"start" => params} = event, socket) do
    socket =
      if event["_target"] == ["start", "channel_name"],
        do: assign(socket, :start_name_typed, true),
        else: socket

    # another repository has other sections: the playbook's default applies again
    params =
      if event["_target"] == ["start", "repository_id"],
        do: Map.drop(params, ["section", "section_new"]),
        else: params

    {:noreply, assign_start(socket, params)}
  end

  # The brief's files: the uploads are stored as documents first, then the
  # run starts with their ids and the picks'. Nothing is stored while an
  # upload is unfinished or the files are over the limit; once stored, a
  # failed start keeps them as picks, so a retry sends the same files.
  def handle_event("start_playbook", %{"start" => params}, socket) do
    params = start_params(socket, params)
    upload = socket.assigns.uploads.brief_files
    picked = socket.assigns.brief_picked
    max = Messages.max_attachments()

    cond do
      upload_errors(upload) != [] or
          Enum.any?(upload.entries, &(not &1.done? or not &1.valid?)) ->
        {:noreply,
         put_flash(socket, :error, "A file is still uploading, or failed; wait or remove it.")}

      length(upload.entries) + length(picked) > max ->
        {:noreply, put_flash(socket, :error, "At most #{max} files on a brief; remove some.")}

      true ->
        # consumed entries leave the upload only after this reply renders
        refs = Enum.map(upload.entries, & &1.ref)
        socket = update(socket, :consumed_refs, &(refs ++ &1))

        case Attachments.store_uploads(socket, :brief_files, %{user_id: Users.local().id}) do
          {:error, stored} ->
            {:noreply,
             socket
             |> keep_files(stored)
             |> put_flash(:error, "A file couldn't be saved; try attaching it again.")}

          {:ok, stored} ->
            ids = stored ++ Enum.map(picked, & &1.id)

            case PlaybookStart.start(Map.put(params, "document_ids", ids)) do
              {:ok, run} ->
                {:noreply,
                 socket
                 |> put_flash(
                   :info,
                   "Started #{run.playbook_name} in ##{run.channel.name}#{filed_in(run.channel)}."
                 )
                 |> push_navigate(to: ~p"/channels/#{run.channel_id}")}

              {:error, reason} ->
                {:noreply,
                 socket
                 |> keep_files(stored)
                 |> assign_start_page()
                 |> assign_start(params)
                 |> put_flash(:error, PlaybookBuilder.plain_words(reason))}
            end
        end
    end
  end

  # Uploads only progress through the hidden upload form's phx-change.
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :brief_files, ref)}

  def handle_event("open_library", _params, socket),
    do: {:noreply, load_library(socket, "")}

  def handle_event("close_library", _params, socket),
    do: {:noreply, assign(socket, :library, nil)}

  def handle_event("search_library", %{"q" => q}, socket),
    do: {:noreply, load_library(socket, q)}

  def handle_event("pick_document", %{"id" => id}, socket) do
    picked = socket.assigns.brief_picked

    cond do
      Enum.any?(picked, &(&1.id == id)) ->
        {:noreply, assign(socket, :library, nil)}

      brief_full?(socket.assigns) ->
        {:noreply,
         socket
         |> assign(:library, nil)
         |> put_flash(:error, "At most #{Messages.max_attachments()} files on a brief.")}

      document = Documents.get(id) ->
        {:noreply, socket |> assign(:brief_picked, picked ++ [document]) |> assign(:library, nil)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("unpick_document", %{"id" => id}, socket),
    do: {:noreply, update(socket, :brief_picked, &Enum.reject(&1, fn doc -> doc.id == id end))}

  # -- Helpers -------------------------------------------------------------------------

  # After a failed start: the stored uploads join the picks (uploads first,
  # as they were sent), and any file deleted meanwhile drops out.
  defp keep_files(socket, stored_ids) do
    kept =
      (stored_ids ++ Enum.map(socket.assigns.brief_picked, & &1.id))
      |> Enum.uniq()
      |> Enum.map(&Documents.get/1)
      |> Enum.reject(&is_nil/1)

    assign(socket, :brief_picked, kept)
  end

  defp load_library(socket, q) do
    exclude = Enum.map(socket.assigns.brief_picked, & &1.id)
    assign(socket, :library, %{q: q, documents: Attachments.library(q, exclude)})
  end

  defp brief_files(assigns),
    do: length(brief_upload(assigns).entries) + length(assigns.brief_picked)

  # the brief's upload less the entries already stored as picks
  defp brief_upload(%{uploads: %{brief_files: upload}, consumed_refs: refs}),
    do: %{upload | entries: Enum.reject(upload.entries, &(&1.ref in refs))}

  defp brief_full?(assigns), do: brief_files(assigns) >= Messages.max_attachments()

  # "drafts can't be starred; enable it first" -> "Drafts can't … first."
  defp sentence(reason) do
    {first, rest} = reason |> PlaybookBuilder.plain_words() |> String.split_at(1)
    String.upcase(first) <> rest <> "."
  end

  defp agent_draft?(%Playbook{source: "agent", enabled: false}), do: true
  defp agent_draft?(_playbook), do: false

  defp parse_version(nil), do: nil

  defp parse_version(text) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp load_list(socket) do
    playbooks = Playbooks.list()

    definitions = Map.new(playbooks, &{&1.id, ok_definition(&1)})

    socket
    |> assign(:playbooks, playbooks)
    |> assign(:definitions, definitions)
    |> assign(:titles, Map.new(playbooks, &{&1.id, title(&1, definitions[&1.id])}))
    |> assign(:people, Map.new(playbooks, &{&1.id, people(definitions[&1.id])}))
    |> assign(:active_runs, Playbooks.active_runs())
    |> assign(:last_runs, Playbooks.last_run_at())
  end

  # The agents a run would use with no overrides, in step order: each step's
  # owners as the start page would fill them, the lead only where it owns a
  # step, each agent once, roles nobody fills left out.
  defp people(nil), do: []

  defp people(definition) do
    roster = Map.new(Runs.roster_preview(definition), &{&1.role, &1.agent})
    lead = Runs.default_coordinator(definition, nil)

    definition.steps
    |> Enum.flat_map(& &1.owner)
    |> Enum.map(fn
      "coordinator" -> lead
      role -> roster[role]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  # The index's sections, each sorted by title and narrowed by the filter:
  # `%{starred, other, drafts}` with `total` counts before filtering. A
  # disabled playbook is a draft, starred or not (its star is kept, hidden).
  defp sections(assigns) do
    by_title = Enum.sort_by(assigns.playbooks, &String.downcase(title_of(assigns.titles, &1)))

    {drafts, enabled} = Enum.split_with(by_title, &(!&1.enabled))
    {starred, other} = Enum.split_with(enabled, &(&1.starred_at != nil))

    for {key, list} <- [starred: starred, other: other, drafts: drafts], into: %{} do
      {key, %{all: list, shown: Enum.filter(list, &matches?(&1, assigns.titles, assigns.filter))}}
    end
  end

  # A case-insensitive substring of the title, description or name.
  defp matches?(playbook, titles, q) do
    case q |> to_string() |> String.trim() |> String.downcase() do
      "" ->
        true

      q ->
        [title_of(titles, playbook), playbook.description || "", playbook.name]
        |> Enum.any?(&String.contains?(String.downcase(&1), q))
    end
  end

  # The Copy card's rows as shown: starred (and enabled) first, then the
  # rest, each by title, narrowed by the filter on title and name. The
  # default pick is the first of them.
  defp copy_rows(assigns, q) do
    q = q |> to_string() |> String.trim() |> String.downcase()

    assigns.playbooks
    |> Enum.filter(fn p ->
      q == "" or
        Enum.any?(
          [title_of(assigns.titles, p), p.name],
          &String.contains?(String.downcase(&1), q)
        )
    end)
    |> Enum.sort_by(&{!copy_starred?(&1), String.downcase(title_of(assigns.titles, &1))})
  end

  defp copy_starred?(%Playbook{enabled: true, starred_at: %DateTime{}}), do: true
  defp copy_starred?(_playbook), do: false

  defp later(%DateTime{} = a, %DateTime{} = b),
    do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp later(a, b), do: max(a, b)

  defp ok_definition(playbook) do
    case Playbooks.definition(playbook) do
      {:ok, d} -> d
      {:error, _} -> nil
    end
  end

  # The project manager knows the team and the runs, so it drafts by default.
  defp lead_like(agents) do
    Enum.find(agents, &(&1.name == "project-manager")) ||
      Enum.find(
        agents,
        &Regex.match?(~r/lead|manager|coordinat|\bpm\b/i, "#{&1.name} #{&1.role}")
      ) ||
      List.first(agents)
  end

  # What the start page shows that the form doesn't change: the parsed
  # definition, who fills each role, where it can run. Once per visit (and
  # after a failed start), not on every keystroke.
  defp assign_start_page(socket) do
    playbook = socket.assigns.playbook
    definition = ok_definition(playbook)

    coordinator_id =
      case definition && Runs.default_coordinator(definition, nil) do
        %{id: id} -> id
        _ -> nil
      end

    socket
    |> assign(:definition, definition)
    |> assign(:start_title, title(playbook, definition))
    |> assign(:start_rows, if(definition, do: Runs.roster_preview(definition), else: []))
    |> assign(:start_repositories, Repositories.list())
    |> assign(:start_channel_groups, PlaybookStart.channel_groups())
    |> assign(:start_coordinator_id, coordinator_id)
    |> assign(:start_channel_name, nil)
    |> assign(:start_name_typed, false)
  end

  # The start form's state: the playbook's defaults, then what was typed.
  defp assign_start(socket, params) do
    %{playbook: playbook, start_rows: rows, start_repositories: repositories} = socket.assigns

    runs_in = params["runs_in"] || "new"

    repository_id =
      params["repository_id"] || (List.first(repositories) && List.first(repositories).id)

    roles =
      Map.new(rows, fn row ->
        {row.role, get_in(params, ["roles", row.role]) || (row.agent && row.agent.name) || ""}
      end)

    name_typed = name_typed?(socket, params["channel_name"])
    socket = assign(socket, :start_name_typed, name_typed)

    {channel_name, socket} =
      if name_typed,
        do: {params["channel_name"], socket},
        else: suggested_channel_name(socket, playbook, params["brief"], repository_id)

    # what the channel will really be called: a typed name cleaned the way
    # `Runs` cleans it, or the suggestion when it cleans to nothing
    new_name =
      if name_typed,
        do: Runs.channel_name(repository_id, channel_name, playbook.name, params["brief"]),
        else: channel_name

    sections = section_names(socket.assigns.repositories, repository_id)

    {section, section_new} =
      start_section(params, sections, repository_id, socket.assigns.definition)

    form =
      to_form(
        %{
          "playbook_id" => playbook.id,
          "brief" => params["brief"] || "",
          "runs_in" => runs_in,
          "repository_id" => repository_id,
          "channel_id" => params["channel_id"] || "",
          "channel_name" => channel_name,
          "section" => section,
          "section_new" => section_new,
          "coordinator_id" => params["coordinator_id"] || socket.assigns.start_coordinator_id,
          "roles" => roles
        },
        as: :start,
        id: "start-run-form"
      )

    socket
    |> assign(:start_form, form)
    |> assign(:start_new_name, new_name)
    |> assign(:start_sections, sections)
  end

  # The repository's sections by position, from Nav's repositories.
  defp section_names(repositories, repository_id) do
    case Enum.find(repositories, &(&1.id == repository_id)) do
      %{sections: sections} when is_list(sections) -> Enum.map(sections, & &1.name)
      _ -> []
    end
  end

  # The section picker: what was chosen, else the playbook's `section:` (an
  # existing section, found the way Runs will find it; else "New section…"
  # with its name; else none). `{choice, new_name}`; choice is a section
  # name, "" or "New section…".
  defp start_section(%{"section" => choice} = params, sections, _repository_id, _definition)
       when is_binary(choice) do
    if choice in ["", @new_section] or choice in sections,
      do: {choice, params["section_new"] || ""},
      else: {@new_section, choice}
  end

  defp start_section(_params, _sections, repository_id, definition) do
    case definition && definition.section do
      name when is_binary(name) and name != "" ->
        case repository_id && Sections.find_by_name(repository_id, name) do
          %{name: found} -> {found, ""}
          _ -> {@new_section, name}
        end

      _ ->
        {"", ""}
    end
  end

  # Where a run's new channel was filed, for the flash.
  defp filed_in(%{section: %{name: name, created?: true}}), do: " in the new section #{name}"
  defp filed_in(%{section: %{name: name}}), do: " in #{name}"
  defp filed_in(_channel), do: ""

  # " in Releases" for the consequence line, when a section is picked.
  defp in_section(form) do
    case {form[:section].value, String.trim(form[:section_new].value || "")} do
      {@new_section, ""} -> ""
      {@new_section, name} -> " in the new section #{name}"
      {name, _} when name in [nil, ""] -> ""
      {name, _} -> " in #{name}"
    end
  end

  # The name field was typed in when it was ever the change's target, or
  # holds something other than the name we last suggested. Kept on the
  # server: a JS-command flag on the form is lost when a change in flight
  # patches it (see NOTES, LiveView gotcha).
  defp name_typed?(_socket, nil), do: false

  defp name_typed?(socket, name) do
    socket.assigns.start_name_typed or
      case socket.assigns.start_channel_name do
        {_key, ^name} -> false
        _ -> true
      end
  end

  # The name `Runs.start` would give the new channel. Looking for a free one
  # reads the channels, so only when the brief's first words or the
  # repository change.
  defp suggested_channel_name(socket, playbook, brief, repository_id) do
    key = {Runs.channel_name_base(playbook.name, brief), repository_id}

    case socket.assigns.start_channel_name do
      {^key, name} ->
        {name, socket}

      _ ->
        {base, repo} = key
        name = Runs.free_channel_name(repo, base)
        {name, assign(socket, :start_channel_name, {key, name})}
    end
  end

  defp start_params(socket, params) do
    params
    |> Map.put("playbook_id", socket.assigns.playbook.id)
    |> then(fn p ->
      if name_typed?(socket, p["channel_name"]), do: p, else: Map.delete(p, "channel_name")
    end)
  end

  # The `# Title` the builder shows, from the parsed body; the name, in
  # words, for a playbook that doesn't parse.
  defp title(%Playbook{name: name}, nil), do: PlaybookBuilder.humanize(name)
  defp title(%Playbook{}, %Definition{} = definition), do: Writer.draft(definition).title

  defp title_of(titles, %Playbook{id: id} = playbook),
    do: Map.get(titles, id) || PlaybookBuilder.humanize(playbook.name)

  defp arrows(definition), do: Enum.map_join(definition.steps, " → ", & &1.title)

  defp stall_text(nil), do: "never nudges the lead"
  defp stall_text(m) when m < 60, do: "nudges the lead after #{m} min quiet"
  defp stall_text(m) when rem(m, 60) == 0, do: "nudges the lead after #{div(m, 60)} h quiet"
  defp stall_text(m), do: "nudges the lead after #{div(m, 60)} h #{rem(m, 60)} min quiet"

  # who does each step, given the form's choices: "@backend + @frontend"
  defp step_agents(step, form, agents) do
    by_id = Map.new(agents, &{&1.id, &1})
    roles = form[:roles].value || %{}

    step.owner
    |> Enum.map(fn
      "coordinator" ->
        case by_id[form[:coordinator_id].value] do
          nil -> "the lead"
          agent -> "@" <> agent.name
        end

      role ->
        case roles[role] do
          name when name in [nil, ""] -> "no #{PlaybookBuilder.humanize(role)} yet"
          name -> "@" <> name
        end
    end)
    |> Enum.join(" + ")
  end

  defp playbooks_count(1), do: "1 playbook"
  defp playbooks_count(n), do: "#{n} playbooks"

  # one expression, so no template whitespace lands before the punctuation
  defp consequence_html(parts) do
    {:safe,
     Enum.map(parts, fn
       {:strong, part} -> ["<strong>", Phoenix.HTML.Engine.html_escape(part), "</strong>"]
       {:text, part} -> Phoenix.HTML.Engine.html_escape(part)
     end)}
  end

  # The footer's line, as `{:text | :strong, part}`s: who is woken where,
  # and with how many files.
  defp consequence(form, new_name, agents, definition, channel_groups, files) do
    lead =
      case Enum.find(agents, &(&1.id == form[:coordinator_id].value)) do
        nil -> "The lead"
        agent -> "@" <> agent.name
      end

    brief? = String.trim(form[:brief].value || "") != ""

    channel =
      Enum.find_value(channel_groups, fn {_repo, channels} ->
        Enum.find(channels, &(&1.id == form[:channel_id].value))
      end)

    where =
      cond do
        form[:runs_in].value == "new" -> {:new, "##{new_name}#{in_section(form)}"}
        channel -> {:in, "##{channel.name}"}
        true -> {:in, "the channel you pick"}
      end

    team = if definition && definition.team, do: " @#{definition.team} joins it.", else: ""
    files_word = if files == 1, do: "1 file", else: "#{files} files"

    posted =
      if brief?,
        do: " The files post with the brief as the run's first message.",
        else: " The files post as the run's first message."

    case {where, files} do
      {{:new, name}, 0} ->
        woken = if brief?, do: "is woken with your brief", else: "is woken"
        [text: "#{lead} #{woken} and opens #{name}.#{team}"]

      {{:in, name}, 0} ->
        [text: "#{lead} is woken in #{name}.#{team}"]

      {{:new, name}, _} ->
        woken = if brief?, do: "is woken with your brief and ", else: "is woken with "

        [
          text: "#{lead} #{woken}",
          strong: files_word,
          text: ", and opens #{name}.#{posted}#{team}"
        ]

      {{:in, name}, _} ->
        [text: "#{lead} is woken in #{name} with ", strong: files_word, text: ".#{posted}#{team}"]
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      repositories={@repositories}
      agents={@agents}
      dms={@dms}
      unread={@unread}
      threads_unread={@threads_unread}
      attention={@attention}
      schedule_counts={@schedule_counts}
      engine_pauses={@engine_pauses}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
      palette={@palette}
      setup={@setup}
      socket={@socket}
    >
      <%= case @live_action do %>
        <% :index -> %>
          <.index_page {assigns} />
        <% :new -> %>
          <.new_page {assigns} />
        <% :start -> %>
          <.start_page {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  defp index_page(assigns) do
    sections = sections(assigns)
    filtering? = String.trim(assigns.filter) != ""
    shown = Enum.sum(for {_key, sec} <- sections, do: length(sec.shown))

    assigns =
      assigns
      |> assign(:sections, sections)
      |> assign(:filtering?, filtering?)
      |> assign(:shown_count, shown)
      |> assign(:agent_drafts, Enum.filter(assigns.playbooks, &agent_draft?/1))
      |> assign(:any_starred?, sections.starred.all != [])

    ~H"""
    <Layouts.page
      title="Playbooks"
      subtitle="Processes your agents run step by step, with Canopy keeping track"
      max_width="max-w-6xl"
    >
      <:actions>
        <.link navigate={~p"/agents/import"} id="import-playbook" class="btn btn-ghost btn-sm">
          Import file
        </.link>
        <.link navigate={~p"/playbooks/new"} id="new-playbook" class="btn btn-sm btn-primary">
          <.icon name="hero-plus" class="size-4" /> New playbook
        </.link>
      </:actions>

      <Layouts.empty_state
        :if={@playbooks == []}
        id="playbooks-empty"
        icon="hero-book-open"
        title="No playbooks yet"
      >
        A playbook names the roles and steps of a process you repeat, like fixing a bug. Ask an
        agent to run it, or start it here. <.link
          navigate={~p"/playbooks/new"}
          class="link link-primary"
        >Write one</.link>.
      </Layouts.empty_state>

      <div :if={@playbooks != []} class="flex flex-wrap items-center gap-3">
        <.form
          for={%{}}
          id="playbook-filter"
          phx-change="filter"
          phx-submit="filter"
          class="w-full sm:w-80"
        >
          <label class="input input-sm w-full bg-base-100">
            <.icon name="hero-magnifying-glass-mini" class="size-4 text-base-content/45" />
            <input
              type="search"
              id="playbook-filter-input"
              name="q"
              value={@filter}
              placeholder="Filter playbooks"
              aria-label="Filter playbooks"
              autocomplete="off"
              class="[&::-webkit-search-cancel-button]:appearance-none"
              phx-debounce="100"
              phx-keydown="clear_filter"
              phx-key="Escape"
            />
            <button
              :if={@filtering?}
              type="button"
              id="playbook-filter-clear"
              class="btn btn-ghost btn-xs btn-square"
              phx-click="clear_filter"
              aria-label="Clear filter"
            >
              <.icon name="hero-x-mark-mini" class="size-3.5" />
            </button>
          </label>
        </.form>
        <p id="playbook-count" class="text-sm text-base-content/55">
          {if @filtering?,
            do: "#{@shown_count} of #{playbooks_count(length(@playbooks))}",
            else: playbooks_count(length(@playbooks))}
          <span :if={!@any_starred? and !@filtering?} id="playbook-star-hint">
            · Star <.icon name="hero-star" class="-mt-0.5 size-3.5" />
            the ones you run most to keep them on top
          </span>
        </p>
        <div
          :if={@agent_drafts != []}
          id="playbook-draft-notice"
          class="ml-auto flex items-center gap-2 rounded-box border border-warning/40 bg-warning/5 px-3 py-1.5 text-sm"
        >
          <span class="text-warning" aria-hidden="true">●</span>
          <%= case @agent_drafts do %>
            <% [draft] -> %>
              <span>
                {if draft.created_by, do: "@#{draft.created_by.name}", else: "An agent"} drafted
                <strong>{title_of(@titles, draft)}</strong>
                for you to review
              </span>
              <.link
                navigate={~p"/playbooks/#{draft.id}/edit"}
                id="playbook-draft-notice-review"
                class="link link-primary font-medium"
              >
                Review
              </.link>
            <% several -> %>
              <span>{length(several)} drafts from agents to review</span>
              <button
                type="button"
                id="playbook-draft-notice-review"
                class="link link-primary font-medium"
                phx-click={JS.push("open_drafts") |> JS.focus(to: "#toggle-drafts")}
              >
                Review
              </button>
          <% end %>
        </div>
      </div>

      <div :if={@playbooks != []} id="playbooks" class="flex flex-col gap-6">
        <p
          :if={@filtering? and @shown_count == 0}
          id="playbooks-no-match"
          class="text-sm text-base-content/60"
        >
          No playbooks match "{String.trim(@filter)}".
          <button type="button" class="link" phx-click="clear_filter">Clear filter</button>
        </p>

        <section :if={@sections.starred.shown != []} aria-labelledby="playbooks-starred-heading">
          <h2 id="playbooks-starred-heading" class={section_heading()}>
            <.icon name="hero-star-solid" class="size-3.5 text-warning" /> Starred
            <span class="font-normal">{section_count(@sections.starred, @filtering?)}</span>
          </h2>
          <ul id="playbooks-starred" class={list_box()}>
            <.playbook_row
              :for={playbook <- @sections.starred.shown}
              {row_attrs(assigns, playbook)}
            />
          </ul>
        </section>

        <section :if={@sections.other.shown != []} aria-labelledby="playbooks-other-heading">
          <h2 id="playbooks-other-heading" class={section_heading()}>
            {if @any_starred?, do: "Other playbooks", else: "All playbooks"}
            <span class="font-normal">{section_count(@sections.other, @filtering?)}</span>
          </h2>
          <ul id="playbooks-other" class={list_box()}>
            <.playbook_row
              :for={playbook <- @sections.other.shown}
              {row_attrs(assigns, playbook)}
            />
          </ul>
        </section>

        <section :if={@sections.drafts.shown != []} aria-labelledby="toggle-drafts">
          <div class="mb-2 flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <button
              type="button"
              id="toggle-drafts"
              class="flex items-center gap-1 text-sm text-base-content/70 hover:text-base-content"
              phx-click="toggle_drafts"
              aria-expanded={to_string(drafts_open?(assigns))}
              aria-controls="playbooks-drafts"
            >
              <.icon
                name={
                  if drafts_open?(assigns),
                    do: "hero-chevron-down-mini",
                    else: "hero-chevron-right-mini"
                }
                class="size-4"
              /> Drafts
              <span class="text-base-content/50">
                {section_count(@sections.drafts, @filtering?)}
              </span>
            </button>
            <span class="text-xs text-base-content/55">
              Agents can't see or run drafts until you enable them. Drafts can't be starred.
            </span>
          </div>
          <ul
            :if={drafts_open?(assigns)}
            id="playbooks-drafts"
            class={[list_box(), "border-dashed"]}
          >
            <.playbook_row
              :for={playbook <- @sections.drafts.shown}
              {row_attrs(assigns, playbook)}
            />
          </ul>
        </section>
      </div>
    </Layouts.page>
    """
  end

  defp section_heading,
    do:
      "mb-2 flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/55"

  defp list_box,
    do: "rounded-box border border-base-300 bg-base-200 divide-y divide-base-300"

  defp section_count(%{all: all, shown: shown}, true), do: "#{length(shown)} of #{length(all)}"
  defp section_count(%{all: all}, false), do: "#{length(all)}"

  # a filter opens Drafts while it's on, so its matches show
  defp drafts_open?(assigns),
    do: assigns.drafts_open? or String.trim(assigns.filter) != ""

  defp row_attrs(assigns, playbook) do
    %{
      playbook: playbook,
      title: title_of(assigns.titles, playbook),
      definition: assigns.definitions[playbook.id],
      people: Map.get(assigns.people, playbook.id, []),
      runs: Map.get(assigns.active_runs, playbook.id, []),
      last_run: assigns.last_runs[playbook.id],
      by_name: assigns.by_name,
      filter: assigns.filter,
      open: assigns.open_id == playbook.id,
      moved: assigns.moved_id == playbook.id
    }
  end

  defp new_page(assigns) do
    assigns = assign(assigns, :copy_rows, copy_rows(assigns, assigns.copy_q))

    ~H"""
    <Layouts.page title="New playbook" max_width="max-w-6xl">
      <:actions>
        <.link navigate={~p"/playbooks"} id="cancel-new" class="btn btn-ghost btn-sm">Cancel</.link>
      </:actions>
      <div class="py-4 text-center">
        <h2 class="text-2xl font-semibold">How do you want to start?</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Whichever you pick, you finish in the same editor and can change everything.
        </p>
      </div>

      <.form
        for={%{}}
        id="new-playbook-form"
        phx-change="new_change"
        phx-submit="new_noop"
        class="grid gap-4 lg:grid-cols-3"
      >
        <%!-- Copy --%>
        <section
          id="new-copy"
          class="new-card flex flex-col rounded-box border border-base-300 bg-base-200 p-5 focus-within:border-primary/50 focus-within:ring-2 focus-within:ring-primary/15"
        >
          <span class="flex size-9 items-center justify-center rounded-lg bg-primary/10 text-primary">
            <.icon name="hero-document-duplicate" class="size-5" />
          </span>
          <h3 class="mt-3 font-semibold">Copy a playbook</h3>
          <p class="text-sm text-base-content/60">
            Start from one that already works and change what's different.
          </p>
          <label :if={length(@playbooks) > 5} class="input input-sm mt-4 w-full bg-base-100">
            <.icon name="hero-magnifying-glass-mini" class="size-4 text-base-content/45" />
            <input
              type="search"
              id="copy-filter"
              name="copy_q"
              value={@copy_q}
              placeholder={"Filter #{length(@playbooks)} playbooks"}
              aria-label="Filter playbooks to copy"
              autocomplete="off"
              phx-debounce="100"
            />
          </label>
          <fieldset class="mt-2 flex flex-1 flex-col">
            <legend class="sr-only">Playbook to copy</legend>
            <p :if={@playbooks == []} class="text-xs text-base-content/50">
              No playbooks to copy yet.
            </p>
            <p
              :if={@playbooks != [] and @copy_rows == []}
              id="copy-no-match"
              class="text-xs text-base-content/60"
            >
              No playbooks match "{String.trim(@copy_q)}".
            </p>
            <ul
              :if={@copy_rows != []}
              id="copy-list"
              phx-hook="ScrollChecked"
              class={[
                "max-h-64 overflow-y-auto rounded-lg border border-base-300 bg-base-100 divide-y divide-base-300",
                length(@copy_rows) > 6 &&
                  "[mask-image:linear-gradient(to_bottom,black_88%,transparent)]"
              ]}
            >
              <li
                :for={playbook <- @copy_rows}
                id={"copy-row-#{playbook.id}"}
                class={@copy_id == playbook.id && "bg-primary/5"}
              >
                <label class={[
                  "flex h-9 cursor-pointer items-center gap-2.5 px-3 text-sm",
                  @copy_id == playbook.id && "font-medium"
                ]}>
                  <input
                    type="radio"
                    name="copy_id"
                    value={playbook.id}
                    checked={@copy_id == playbook.id}
                    class="radio radio-xs radio-primary"
                  />
                  <span class="min-w-0 flex-1 truncate">{title_of(@titles, playbook)}</span>
                  <.icon
                    :if={copy_starred?(playbook)}
                    name="hero-star-solid"
                    class="size-3.5 shrink-0 text-warning"
                  />
                  <span
                    :if={@definitions[playbook.id]}
                    class="shrink-0 text-xs font-normal text-base-content/45"
                  >
                    {length(@definitions[playbook.id].steps)} steps
                  </span>
                </label>
                <p
                  :if={@copy_id == playbook.id && @definitions[playbook.id]}
                  class="line-clamp-2 pb-2 pl-[34px] pr-3 text-xs text-base-content/60"
                  title={arrows(@definitions[playbook.id])}
                >
                  {arrows(@definitions[playbook.id])}
                </p>
              </li>
            </ul>
          </fieldset>
          <button
            type="button"
            id="copy-playbook"
            class={["btn btn-block mt-4", @copy_id && "btn-primary", !@copy_id && "new-card-go"]}
            phx-click="copy"
            disabled={is_nil(@copy_id)}
          >
            Copy {(Enum.find(@playbooks, &(&1.id == @copy_id)) || %{name: ""})
            |> then(&if(&1.name == "", do: "", else: title_of(@titles, &1)))}
          </button>
        </section>

        <%!-- Blank --%>
        <section
          id="new-blank"
          class="new-card flex flex-col rounded-box border border-base-300 bg-base-200 p-5 focus-within:border-primary/50 focus-within:ring-2 focus-within:ring-primary/15"
        >
          <span class="flex size-9 items-center justify-center rounded-lg bg-base-100 text-base-content/70">
            <.icon name="hero-plus" class="size-5" />
          </span>
          <h3 class="mt-3 font-semibold">Start blank</h3>
          <p class="text-sm text-base-content/60">
            One empty step and sensible settings. Good when you know the process.
          </p>
          <div
            class="mt-4 flex flex-1 flex-col gap-2 rounded-lg border border-dashed border-base-300 p-3"
            aria-hidden="true"
          >
            <div class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content/45">
              <span class="flex size-5 items-center justify-center rounded-full bg-base-200 text-[10px]">1</span>
              What happens first?
            </div>
            <div class="rounded-lg border border-dashed border-base-300 py-1.5 text-center text-xs text-base-content/45">
              + Add step
            </div>
          </div>
          <.link
            navigate={~p"/playbooks/new/blank"}
            id="start-blank"
            class="new-card-go btn btn-block mt-4"
          >
            Start blank
          </.link>
        </section>

        <%!-- Describe --%>
        <section
          id="new-describe"
          class="new-card flex flex-col rounded-box border border-base-300 bg-base-200 p-5 focus-within:border-primary/50 focus-within:ring-2 focus-within:ring-primary/15"
        >
          <span class="flex size-9 items-center justify-center rounded-lg bg-secondary/10 text-secondary">
            <.icon name="hero-sparkles" class="size-5" />
          </span>
          <h3 class="mt-3 font-semibold">Describe it to an agent</h3>
          <p class="text-sm text-base-content/60">
            Say how the work should go. An agent drafts the steps for you to check.
          </p>
          <label for="describe-text" class="sr-only">How the work should go</label>
          <textarea
            id="describe-text"
            name="describe"
            rows="6"
            phx-debounce="300"
            placeholder="e.g. When I tag a release, collect the merged PRs, draft release notes, have the reviewer check them against the PRs, then let me approve before anything is published."
            class="textarea mt-4 w-full flex-1 text-sm"
          >{@describe}</textarea>
          <div class="mt-2 flex items-center gap-2 text-sm">
            <label for="describe-drafter" class="text-base-content/60">Drafted by</label>
            <select id="describe-drafter" name="drafter" class="select select-sm min-w-0 flex-1">
              <option
                :for={agent <- @active_agents}
                value={agent.name}
                selected={@drafter && @drafter.name == agent.name}
              >
                @{agent.name}
              </option>
            </select>
          </div>
          <button
            type="button"
            id="describe-playbook"
            class="new-card-go btn btn-block mt-4"
            phx-click="describe"
            disabled={is_nil(@drafter)}
          >
            Ask {if @drafter, do: "@#{@drafter.name}", else: "an agent"}
          </button>
        </section>
      </.form>

      <p class="text-center text-sm text-base-content/60">
        Have a playbook file? <.link navigate={~p"/agents/import"} class="link">Import it</.link>
      </p>
    </Layouts.page>
    """
  end

  defp start_page(assigns) do
    ~H"""
    <Layouts.page title={@start_title} subtitle="Start a run" max_width="max-w-6xl">
      <:actions>
        <.link navigate={~p"/playbooks"} id="cancel-start" class="btn btn-ghost btn-sm">Cancel</.link>
      </:actions>

      <p
        :if={!@playbook.enabled}
        id="start-disabled"
        class="rounded-box border border-warning/40 bg-warning/5 px-4 py-3 text-sm"
      >
        {@start_title} is disabled.
        <.link navigate={~p"/playbooks/#{@playbook.id}/edit"} class="link">Enable it</.link>
        first.
      </p>
      <p :if={is_nil(@definition)} class="text-sm text-error">
        This playbook has problems.
        <.link navigate={~p"/playbooks/#{@playbook.id}/edit"} class="link">Open it</.link>
        to see them.
      </p>

      <div :if={@definition} class="grid items-start gap-4 lg:grid-cols-[1fr_360px]">
        <%!-- Files travel through their own form, as in the channel composer:
             uploads need a phx-change, and the start form's own change reads
             `_target`. The whole start form is the drop target. --%>
        <form
          id="start-upload-form"
          phx-change="validate_upload"
          phx-submit="validate_upload"
          class="hidden"
        >
          <.live_file_input upload={@uploads.brief_files} />
        </form>
        <.form
          for={@start_form}
          id="start-run-form"
          phx-change="start_validate"
          phx-submit="start_playbook"
          phx-drop-target={@uploads.brief_files.ref}
          class="group/drop rounded-box border border-base-300 bg-base-200 p-5 sm:p-6"
        >
          <label for="start-brief" class="block font-semibold">
            What's this run about?
            <span class="text-sm font-normal text-base-content/60">Optional</span>
          </label>
          <p
            :if={@definition.inputs}
            id="start-inputs"
            class="mt-0.5 whitespace-pre-line text-xs text-base-content/60"
          >
            {@definition.inputs}
          </p>
          <div
            id="start-brief-box"
            class="relative mt-2 rounded-xl border border-base-300 bg-base-100 p-2 focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20 group-[.phx-drop-target-active]/drop:border-2 group-[.phx-drop-target-active]/drop:border-dashed group-[.phx-drop-target-active]/drop:border-primary group-[.phx-drop-target-active]/drop:bg-primary/5"
          >
            <.file_chips
              id="start-brief-files"
              item="start-"
              upload={brief_upload(assigns)}
              picked={@brief_picked}
              target="brief"
            />
            <textarea
              id="start-brief"
              name="start[brief]"
              rows="4"
              phx-debounce="300"
              phx-hook="PasteUpload"
              data-upload="brief_files"
              class="w-full resize-y bg-transparent px-1 text-[15px] outline-none focus:outline-none"
              placeholder="Leave empty to let the playbook speak for itself"
            >{@start_form[:brief].value}</textarea>
            <div class="mt-1 flex items-center gap-1">
              <label
                for={!brief_full?(assigns) && @uploads.brief_files.ref}
                id="start-brief-attach"
                aria-disabled={brief_full?(assigns) && "true"}
                class={[
                  "btn btn-sm btn-ghost btn-square",
                  brief_full?(assigns) && "btn-disabled",
                  !brief_full?(assigns) && "cursor-pointer"
                ]}
                title="Attach a file from your computer (or paste, or drop one here)"
              >
                <.icon name="hero-folder-open-mini" class="size-4" />
              </label>
              <button
                type="button"
                id="start-brief-library"
                class="btn btn-sm btn-ghost btn-square"
                phx-click="open_library"
                disabled={brief_full?(assigns)}
                title="Attach a file already shared in Canopy"
              >
                <.icon name="hero-paper-clip-mini" class="size-4" />
              </button>
              <span class="text-xs text-base-content/50">
                Drop, paste (⌘V) or attach screenshots and files
              </span>
              <span
                :if={brief_files(assigns) > 0}
                id="start-brief-count"
                class="ml-auto text-xs text-base-content/50"
              >
                {brief_files(assigns)} of {Messages.max_attachments()} files
              </span>
            </div>
            <div
              id="start-brief-drop"
              aria-hidden="true"
              class="pointer-events-none absolute inset-0 hidden items-center justify-center rounded-xl bg-base-100/85 text-sm font-medium text-primary group-[.phx-drop-target-active]/drop:flex"
            >
              Drop to attach to the brief
            </div>
          </div>

          <dl class="mt-5 grid gap-x-4 gap-y-4 text-sm md:grid-cols-[112px_1fr] md:items-center">
            <dt class="text-base-content/60">Runs in</dt>
            <dd class="flex flex-col gap-2">
              <div class="join" role="radiogroup" aria-label="Runs in">
                <label class={[
                  "btn join-item btn-sm border-base-300",
                  @start_form[:runs_in].value == "new" &&
                    "btn-active bg-base-200 font-medium shadow-sm",
                  @start_form[:runs_in].value != "new" &&
                    "bg-base-100 font-normal text-base-content/70"
                ]}>
                  <input
                    type="radio"
                    name="start[runs_in]"
                    value="new"
                    checked={@start_form[:runs_in].value == "new"}
                    class="sr-only"
                  /> New channel
                </label>
                <label class={[
                  "btn join-item btn-sm border-base-300",
                  @start_form[:runs_in].value != "new" &&
                    "btn-active bg-base-200 font-medium shadow-sm",
                  @start_form[:runs_in].value == "new" &&
                    "bg-base-100 font-normal text-base-content/70"
                ]}>
                  <input
                    type="radio"
                    name="start[runs_in]"
                    value="existing"
                    checked={@start_form[:runs_in].value != "new"}
                    class="sr-only"
                  /> Existing channel
                </label>
              </div>
              <div
                :if={@start_form[:runs_in].value == "new"}
                class="flex flex-wrap items-center gap-2"
              >
                <span class="flex min-w-0 flex-1 items-center gap-2">
                  <span class="text-base-content/45">#</span>
                  <input
                    id="start-channel-name"
                    name="start[channel_name]"
                    type="text"
                    value={@start_form[:channel_name].value}
                    phx-debounce="300"
                    aria-label="New channel name"
                    class="input input-sm min-w-0 flex-1 font-medium"
                  />
                </span>
                <span class="text-xs text-base-content/50">in</span>
                <select
                  id="start-repository"
                  name="start[repository_id]"
                  class="select select-sm w-48"
                  aria-label="Repository"
                >
                  <option
                    :for={repo <- @start_repositories}
                    value={repo.id}
                    selected={repo.id == @start_form[:repository_id].value}
                  >
                    {repo.name}
                  </option>
                </select>
              </div>
              <div
                :if={@start_form[:runs_in].value == "new"}
                id="start-section-row"
                class="flex flex-wrap items-center gap-2"
              >
                <label for="start-section" class="text-xs text-base-content/50">Section</label>
                <select id="start-section" name="start[section]" class="select select-sm w-48">
                  <option value="" selected={@start_form[:section].value == ""}>No section</option>
                  <option
                    :for={name <- @start_sections}
                    value={name}
                    selected={name == @start_form[:section].value}
                  >
                    {name}
                  </option>
                  <option
                    value={SectionPicker.new()}
                    selected={@start_form[:section].value == SectionPicker.new()}
                  >
                    New section…
                  </option>
                </select>
                <input
                  :if={@start_form[:section].value == SectionPicker.new()}
                  id="start-section-new"
                  name="start[section_new]"
                  type="text"
                  value={@start_form[:section_new].value}
                  maxlength="40"
                  phx-debounce="300"
                  placeholder="Section name"
                  aria-label="New section name"
                  class="input input-sm min-w-0 flex-1"
                />
              </div>
              <select
                :if={@start_form[:runs_in].value != "new"}
                id="start-channel"
                name="start[channel_id]"
                class="select select-sm w-80 max-w-full"
                aria-label="Channel"
              >
                <option value="" disabled selected={@start_form[:channel_id].value in [nil, ""]}>
                  Pick a channel
                </option>
                <optgroup :for={{repo, channels} <- @start_channel_groups} label={repo}>
                  <option
                    :for={channel <- channels}
                    value={channel.id}
                    disabled={channel.run_active?}
                    selected={channel.id == @start_form[:channel_id].value}
                  >
                    #{channel.name}{if channel.run_active?, do: " · run active"}
                  </option>
                </optgroup>
              </select>
            </dd>

            <dt><label for="start-coordinator" class="text-base-content/60">Led by</label></dt>
            <dd>
              <select
                id="start-coordinator"
                name="start[coordinator_id]"
                class="select select-sm w-80 max-w-full"
              >
                <option value="" selected={@start_form[:coordinator_id].value in [nil, ""]}>
                  Pick a lead
                </option>
                <option
                  :for={agent <- @active_agents}
                  value={agent.id}
                  selected={agent.id == @start_form[:coordinator_id].value}
                >
                  @{agent.name}
                </option>
              </select>
            </dd>

            <dt :if={@start_rows != []} class="self-start pt-1.5 text-base-content/60">
              Who does what
            </dt>
            <dd :if={@start_rows != []} class="flex flex-col divide-y divide-base-300">
              <div
                :for={row <- @start_rows}
                id={"start-role-#{row.role}"}
                class="grid grid-cols-[112px_192px_1fr] items-center gap-3 py-1.5"
              >
                <span class="flex items-center gap-2">
                  <.avatar agent={row.agent} />
                  <label for={"start-role-#{row.role}-agent"} class="font-medium">{PlaybookBuilder.humanize(
                    row.role
                  )}</label>
                </span>
                <select
                  id={"start-role-#{row.role}-agent"}
                  name={"start[roles][#{row.role}]"}
                  class="select select-sm"
                >
                  <option
                    :if={!row.agent}
                    value=""
                    selected={@start_form[:roles].value[row.role] in [nil, ""]}
                  >
                    Pick an agent
                  </option>
                  <option
                    :for={agent <- @active_agents}
                    value={agent.name}
                    selected={agent.name == @start_form[:roles].value[row.role]}
                  >
                    @{agent.name}
                  </option>
                </select>
                <span class={[
                  "text-xs",
                  row.agent && "text-base-content/50",
                  !row.agent && "text-warning"
                ]}>
                  {if row.agent && @start_form[:roles].value[row.role] != row.agent.name,
                    do: "your pick",
                    else: row.source}
                </span>
              </div>
            </dd>
          </dl>

          <div class="mt-5 flex flex-wrap items-center gap-3 border-t border-base-300 pt-4">
            <button
              type="submit"
              id="start-playbook-submit"
              class="btn btn-primary"
              disabled={!@playbook.enabled}
            >
              <.icon name="hero-play-mini" class="size-4" /> Start run
            </button>
            <.link navigate={~p"/playbooks"} class="btn btn-ghost">Cancel</.link>
            <p id="start-consequence" class="min-w-0 flex-1 text-xs text-base-content/60">
              {consequence_html(
                consequence(
                  @start_form,
                  @start_new_name,
                  @active_agents,
                  @definition,
                  @start_channel_groups,
                  brief_files(assigns)
                )
              )}
            </p>
          </div>
        </.form>

        <aside id="start-preview" class="rounded-box border border-base-300 bg-base-200 p-5">
          <h2 class="font-semibold">What will happen</h2>
          <p class="text-xs text-base-content/55">
            {@start_title} · {length(@definition.steps)} steps · {stall_text(@definition.stall_after)}
          </p>
          <ol class="mt-3 flex flex-col divide-y divide-base-300 text-sm">
            <li
              :for={{step, n} <- Enum.with_index(@definition.steps, 1)}
              class="flex items-center gap-2 py-2"
            >
              <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-base-100 text-[10px] text-base-content/60">{n}</span>
              <span class="min-w-0 flex-1">
                {step.title}
                <span :if={step.on_reject} class="text-xs text-secondary">↩︎ {(Definition.step(
                                                                                @definition,
                                                                                step.on_reject
                                                                              ) ||
                                                                                %{
                                                                                  title:
                                                                                    step.on_reject
                                                                                }).title}</span>
                <span
                  :if={step.approval}
                  class="rounded-full bg-warning/10 px-1.5 text-[11px] font-medium text-warning"
                >you approve</span>
                <span :if={step.optional} class="text-[11px] text-base-content/50">may be skipped</span>
              </span>
              <span class="shrink-0 text-xs text-base-content/60">{step_agents(
                step,
                @start_form,
                @active_agents
              )}</span>
            </li>
          </ol>
          <.link navigate={~p"/playbooks/#{@playbook.id}/edit"} class="link mt-3 inline-block text-sm">Edit the playbook</.link>
        </aside>
      </div>
      <.library_picker
        :if={@library}
        library={@library}
        hint="Files already in Canopy, from any chat. Pick one to add it to the brief."
      />
    </Layouts.page>
    """
  end
end
