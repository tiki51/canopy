defmodule CanopyWeb.PlaybookBuilderLive do
  @moduledoc """
  The playbook builder (`/playbooks/new/blank`, `/playbooks/:id/edit`): a
  playbook as an About card, a list of step cards, and ground rules, in the
  product's words ("Lead", "Who does it", "send it back to"). People never
  see YAML; the file stays the same Markdown with YAML frontmatter.

  The page edits a draft (`CanopyWeb.PlaybookBuilder`); every change is
  written out with `Canopy.Playbooks.Writer` and parsed with
  `Canopy.Playbooks.Definition.parse/1`, which stays the source of truth.
  Saving is explicit (an enabled playbook is in every agent's prompt), and
  checks the version the page loaded, so an edit made elsewhere meanwhile is
  never overwritten. A playbook the builder cannot read opens on a card
  that says why, with the old text editor behind a confirm.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Playbooks, Teams}
  alias Canopy.Playbooks.{Definition, Playbook}
  alias CanopyWeb.{PlaybookAsk, PlaybookBuilder}
  import CanopyWeb.PlaybookComponents, only: [avatar: 1]

  @nudges [{15, "15 min"}, {30, "30 min"}, {60, "1 h"}, {120, "2 h"}, {240, "4 h"}]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Playbooks.subscribe()

    active = Agents.list_active()

    {:ok,
     socket
     |> assign(:active_agents, active)
     |> assign(:by_name, Map.new(active, &{&1.name, &1}))
     |> assign(:teams, Teams.list())
     |> assign(:playbook, nil)
     |> assign(:popover, nil)
     |> assign(:owner_query, "")
     |> assign(:open, MapSet.new())
     |> assign(:undo, nil)
     |> assign(:conflict, nil)
     |> assign(:deleted, false)
     |> assign(:unreadable, nil)
     |> assign(:text_form, nil)
     |> assign(:text_body, nil)
     |> assign(:show_all_settings, false)
     |> assign(:editing_guidance, false)
     |> assign(:editing_name, false)
     |> assign(:key_error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        draft = PlaybookBuilder.blank()

        {:noreply,
         socket
         |> assign(:page_title, "New playbook")
         |> assign(:show_all_settings, true)
         |> assign(:saved_text, nil)
         |> assign(:open, MapSet.new(["s1"]))
         |> put_draft(draft)
         |> then(&assign(&1, :saved_text, PlaybookBuilder.text(&1.assigns.draft)))
         |> assign(:dirty, false)}

      :edit ->
        id = params["id"]

        cond do
          match?(%Playbook{id: ^id}, socket.assigns.playbook) ->
            {:noreply, socket}

          playbook = Playbooks.get(id) ->
            {:noreply, load(socket, playbook)}

          true ->
            {:noreply,
             socket
             |> put_flash(:error, "That playbook no longer exists.")
             |> push_navigate(to: ~p"/playbooks")}
        end
    end
  end

  defp load(socket, playbook) do
    playbook = Canopy.Repo.preload(playbook, :created_by, force: true)

    socket =
      socket
      |> assign(:playbook, playbook)
      |> assign(:page_title, playbook.name)
      |> assign(:conflict, nil)
      |> assign(:deleted, false)
      |> assign(:undo, nil)
      |> assign(:popover, nil)
      |> assign(:editing_name, false)

    case Playbooks.definition(playbook) do
      {:ok, definition} ->
        draft = PlaybookBuilder.load(definition)

        socket
        |> assign(:unreadable, nil)
        |> assign(:text_form, nil)
        |> assign(:text_body, nil)
        |> assign(:saved_text, PlaybookBuilder.text(draft))
        |> assign(:open, MapSet.new())
        |> put_draft(draft)

      {:error, reasons} ->
        socket
        |> assign(:unreadable, reasons)
        |> assign(:saved_text, playbook.body)
        |> assign(:draft, nil)
        |> assign(:dirty, false)
        |> assign(:problems, [])
    end
  end

  # Every change goes through here: keys follow titles, the text is written
  # and parsed, and the problems and dirty state follow.
  defp put_draft(socket, draft) do
    draft = draft |> PlaybookBuilder.sync_roles() |> PlaybookBuilder.refresh()
    text = PlaybookBuilder.text(draft)
    parsed = Definition.parse(text)
    problems = PlaybookBuilder.problems(draft, parsed)

    socket
    |> assign(:draft, draft)
    |> assign(:parsed, parsed)
    |> assign(:problems, problems)
    |> assign(:shown_problems, shown_problems(socket, problems))
    |> assign(:rails, PlaybookBuilder.rails(draft))
    |> assign(:dirty, text != socket.assigns[:saved_text])
  end

  defp change(socket, fun), do: put_draft(socket, fun.(socket.assigns.draft))

  # A new playbook starts out incomplete; it is not told off for that (the
  # Create button says what it needs), only for a send-back a move broke.
  defp shown_problems(%{assigns: %{playbook: %Playbook{}}}, problems), do: problems
  defp shown_problems(_socket, problems), do: Enum.filter(problems, &(&1[:kind] == :send_back))

  # -- PubSub ----------------------------------------------------------------------

  @impl true
  def handle_info({:playbooks, :changed}, %{assigns: %{playbook: %Playbook{} = mine}} = socket) do
    # a change elsewhere: follow it unless there are edits to keep
    case Playbooks.get(mine.id) do
      nil when socket.assigns.deleted ->
        {:noreply, socket}

      nil ->
        if unsaved?(socket.assigns),
          do: {:noreply, deleted(socket)},
          else:
            {:noreply,
             socket
             |> put_flash(:error, "#{mine.name} was deleted.")
             |> push_navigate(to: ~p"/playbooks")}

      %Playbook{lock_version: v} = fresh when v != mine.lock_version ->
        if unsaved?(socket.assigns),
          do: {:noreply, assign(socket, :conflict, conflict_line(fresh))},
          else: {:noreply, load(socket, fresh)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:clear_undo, token}, socket) do
    case socket.assigns.undo do
      %{token: ^token} -> {:noreply, assign(socket, :undo, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # a save refused because the playbook moved on: say how
  defp stale(socket) do
    case Playbooks.get(socket.assigns.playbook.id) do
      nil -> deleted(socket)
      fresh -> assign(socket, :conflict, conflict_line(fresh))
    end
  end

  defp deleted(socket) do
    socket
    |> assign(:deleted, true)
    |> assign(:conflict, "This playbook was deleted somewhere else while you were editing.")
  end

  # Edits that would be lost by leaving or reloading: the builder's draft, or
  # the file text being typed.
  defp unsaved?(%{text_form: form} = assigns) when not is_nil(form),
    do: assigns.text_body != assigns.saved_text

  defp unsaved?(assigns), do: assigns.dirty

  defp conflict_line(%Playbook{} = fresh) do
    case Canopy.Repo.preload(fresh, :created_by, force: true) do
      %{source: "agent", created_by: %{name: name}} ->
        "@#{name} changed this playbook while you were editing."

      _ ->
        "This playbook was changed somewhere else while you were editing."
    end
  end

  # -- Typing ----------------------------------------------------------------------

  @impl true
  def handle_event("edit", params, socket) do
    socket = assign(socket, :owner_query, params["owner_query"] || socket.assigns.owner_query)

    {draft, role_error} =
      socket.assigns.draft
      |> put_about(params)
      |> put_steps(params["steps"] || %{})
      |> put_role(params["role"])

    socket = if params["role"], do: assign(socket, :key_error, role_error), else: socket
    {:noreply, put_draft(socket, draft)}
  end

  def handle_event("save", _params, socket), do: save(socket)

  def handle_event("discard", _params, socket) do
    case socket.assigns.playbook do
      nil -> {:noreply, push_navigate(socket, to: ~p"/playbooks")}
      playbook -> {:noreply, load(socket, Playbooks.get(playbook.id) || playbook)}
    end
  end

  # -- Opening and popovers -------------------------------------------------------------

  def handle_event("toggle_step", %{"uid" => uid}, socket) do
    open = socket.assigns.open

    open =
      if MapSet.member?(open, uid), do: MapSet.delete(open, uid), else: MapSet.put(open, uid)

    {:noreply, socket |> assign(:open, open) |> assign(:key_error, nil)}
  end

  def handle_event("popover", %{"id" => id}, socket) do
    popover = if socket.assigns.popover == id, do: nil, else: id

    {:noreply,
     socket |> assign(:popover, popover) |> assign(:owner_query, "") |> assign(:key_error, nil)}
  end

  def handle_event("close_popover", _params, socket),
    do: {:noreply, socket |> assign(:popover, nil) |> assign(:key_error, nil)}

  def handle_event("more_settings", _params, socket),
    do: {:noreply, assign(socket, :show_all_settings, true)}

  def handle_event("edit_guidance", _params, socket),
    do: {:noreply, assign(socket, :editing_guidance, true)}

  def handle_event("edit_name", _params, socket),
    do: {:noreply, assign(socket, :editing_name, true)}

  def handle_event("goto", %{"uid" => uid}, socket) do
    {:noreply,
     socket
     |> assign(:open, MapSet.put(socket.assigns.open, uid))
     |> push_event("builder:flash", %{id: "step-#{uid}"})}
  end

  # -- Settings ----------------------------------------------------------------------------

  def handle_event("set_lead", %{"name" => name}, socket) do
    lead = if name == "", do: nil, else: name
    {:noreply, socket |> assign(:popover, nil) |> change(&%{&1 | coordinator: lead})}
  end

  def handle_event("set_team", %{"name" => name}, socket) do
    team = if name == "", do: nil, else: name
    {:noreply, socket |> assign(:popover, nil) |> change(&%{&1 | team: team})}
  end

  def handle_event("set_channel", %{"value" => value}, socket) when value in ~w(new current),
    do: {:noreply, change(socket, &%{&1 | channel: value})}

  def handle_event("set_nudge", %{"minutes" => minutes}, socket) do
    stall =
      case Integer.parse(to_string(minutes)) do
        {n, _} when n >= 1 and n <= 10_080 -> n
        _ -> nil
      end

    {:noreply, socket |> assign(:popover, nil) |> change(&%{&1 | stall_after: stall})}
  end

  # -- Roles ----------------------------------------------------------------------------------

  def handle_event("add_role", _params, socket) do
    key = PlaybookBuilder.free_role(socket.assigns.draft)

    {:noreply,
     socket
     |> change(&PlaybookBuilder.add_role(&1, key))
     |> assign(:popover, "role:" <> key)
     |> push_event("builder:focus", %{id: "role-name"})}
  end

  def handle_event("remove_role", %{"key" => key}, socket) do
    if PlaybookBuilder.role_uses(socket.assigns.draft, key) == [] do
      {:noreply, socket |> assign(:popover, nil) |> change(&PlaybookBuilder.remove_role(&1, key))}
    else
      {:noreply, socket}
    end
  end

  # -- Owners ------------------------------------------------------------------------------------

  def handle_event("toggle_owner", %{"uid" => uid, "role" => role}, socket),
    do: {:noreply, change(socket, &PlaybookBuilder.toggle_owner(&1, uid, role))}

  def handle_event("owner_agent", %{"uid" => uid, "agent" => name}, socket) do
    draft = socket.assigns.draft

    key =
      case Enum.find(draft.roles, &(&1.agent == name)) do
        %{key: key} -> key
        nil -> PlaybookBuilder.free_role(draft, name)
      end

    {:noreply,
     change(socket, fn d ->
       d
       |> PlaybookBuilder.add_role(key, name)
       |> PlaybookBuilder.toggle_owner(uid, key)
     end)}
  end

  def handle_event("owner_new_role", %{"uid" => uid}, socket) do
    key = PlaybookBuilder.free_role(socket.assigns.draft)

    {:noreply,
     socket
     |> change(fn d ->
       d |> PlaybookBuilder.add_role(key) |> PlaybookBuilder.toggle_owner(uid, key)
     end)
     |> assign(:popover, "role:" <> key)
     |> push_event("builder:focus", %{id: "role-name"})}
  end

  # -- Steps ----------------------------------------------------------------------------------------

  def handle_event("add_step", %{"index" => index} = params, socket) do
    draft = socket.assigns.draft

    if length(draft.steps) >= PlaybookBuilder.max_steps() do
      {:noreply, socket}
    else
      index =
        case Integer.parse(to_string(index)) do
          {n, _} -> n |> min(length(draft.steps)) |> max(0)
          :error -> length(draft.steps)
        end

      {draft, uid} = PlaybookBuilder.add_step(draft, index, params["preset"] || "task")

      popover = if params["preset"] == "parallel", do: "owner:" <> uid, else: nil

      {:noreply,
       socket
       |> put_draft(draft)
       |> assign(:popover, popover)
       |> assign(:open, MapSet.put(socket.assigns.open, uid))
       |> push_event("builder:focus", %{id: "step-#{uid}-title"})}
    end
  end

  def handle_event("duplicate_step", %{"uid" => uid}, socket) do
    if length(socket.assigns.draft.steps) >= PlaybookBuilder.max_steps() do
      {:noreply, socket}
    else
      {draft, new_uid} = PlaybookBuilder.duplicate_step(socket.assigns.draft, uid)

      {:noreply,
       socket
       |> put_draft(draft)
       |> assign(:open, MapSet.put(socket.assigns.open, new_uid))
       |> push_event("builder:focus", %{id: "step-#{new_uid}-title"})}
    end
  end

  def handle_event("delete_step", %{"uid" => uid}, socket) do
    draft = socket.assigns.draft
    {next, undo} = PlaybookBuilder.delete_step(draft, uid)

    if undo do
      token = System.unique_integer([:positive])
      Process.send_after(self(), {:clear_undo, token}, 10_000)

      {:noreply,
       socket
       |> put_draft(next)
       |> assign(:popover, nil)
       |> assign(:undo, Map.merge(undo, %{token: token, text: undo_text(draft, undo)}))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("undo", _params, socket) do
    case socket.assigns.undo do
      nil ->
        {:noreply, socket}

      undo ->
        {:noreply,
         socket
         |> assign(:undo, nil)
         |> change(&PlaybookBuilder.restore(&1, undo))
         |> push_event("builder:flash", %{id: "step-#{undo.step.uid}"})}
    end
  end

  def handle_event("dismiss_undo", _params, socket), do: {:noreply, assign(socket, :undo, nil)}

  def handle_event("move_step", %{"uid" => uid, "delta" => delta}, socket) do
    delta = if delta in ["-1", -1], do: -1, else: 1

    {:noreply,
     socket
     |> assign(:popover, nil)
     |> change(&PlaybookBuilder.move(&1, uid, delta))
     |> push_event("builder:focus", %{id: "grip-#{uid}"})}
  end

  def handle_event("reorder", %{"uids" => uids}, socket) when is_list(uids),
    do: {:noreply, change(socket, &PlaybookBuilder.reorder(&1, uids))}

  def handle_event("set_send_back", %{"uid" => uid, "to" => to}, socket) do
    target = if to == "", do: nil, else: to

    {:noreply,
     change(socket, &PlaybookBuilder.update_step(&1, uid, fn s -> %{s | on_reject: target} end))}
  end

  def handle_event("toggle_flag", %{"uid" => uid, "flag" => flag}, socket)
      when flag in ~w(approval optional send_back) do
    draft = socket.assigns.draft

    {:noreply,
     change(socket, fn d ->
       PlaybookBuilder.update_step(d, uid, fn s ->
         case flag do
           "approval" ->
             %{s | approval: !s.approval}

           "optional" ->
             %{s | optional: !s.optional}

           "send_back" ->
             if s.on_reject do
               %{s | on_reject: nil}
             else
               above = draft |> PlaybookBuilder.send_back_targets(uid) |> List.last()
               %{s | on_reject: above && above.id}
             end
         end
       end)
     end)}
  end

  def handle_event("change_key", %{"uid" => uid, "value" => key}, socket) do
    case PlaybookBuilder.change_key(socket.assigns.draft, uid, key) do
      {:ok, draft} ->
        {:noreply, socket |> assign(:popover, nil) |> assign(:key_error, nil) |> put_draft(draft)}

      {:error, reason} ->
        {:noreply, assign(socket, :key_error, reason)}
    end
  end

  # -- The playbook ------------------------------------------------------------------------------

  def handle_event("toggle_enabled", _params, socket) do
    %{playbook: playbook, dirty: dirty} = socket.assigns

    cond do
      is_nil(playbook) or dirty ->
        {:noreply, socket}

      true ->
        case Playbooks.set_enabled(playbook, not playbook.enabled, playbook.lock_version) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> load(updated)
             |> put_flash(
               :info,
               if(updated.enabled,
                 do: "Enabled #{updated.name}: agents see it from their next turn.",
                 else:
                   "Disabled #{updated.name}: agents no longer see it; runs in progress continue."
               )
             )}

          {:error, :stale} ->
            fresh = Playbooks.get(playbook.id)

            {:noreply,
             socket
             |> load(fresh)
             |> put_flash(
               :error,
               "It changed since the page loaded; read it through, then enable it."
             )}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, "That playbook does not parse; fix it before enabling.")}
        end
    end
  end

  # with unsaved edits, the copy is what the page shows
  def handle_event("duplicate_playbook", _params, socket) do
    if unsaved?(socket.assigns),
      do: save_copy(socket),
      else: duplicate_saved(socket)
  end

  def handle_event("delete_playbook", _params, socket) do
    playbook = socket.assigns.playbook

    case Playbooks.delete(playbook) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{playbook.name}.")
         |> push_navigate(to: ~p"/playbooks")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, String.capitalize(reason) <> ".")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete #{playbook.name}.")}
    end
  end

  def handle_event("load_theirs", _params, socket) do
    case Playbooks.get(socket.assigns.playbook.id) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/playbooks")}
      fresh -> {:noreply, socket |> load(fresh) |> put_flash(:info, "Loaded their version.")}
    end
  end

  def handle_event("save_copy", _params, socket), do: save_copy(socket)

  def handle_event("ask_fix", %{"agent" => name}, socket) do
    playbook = socket.assigns.playbook

    with %{} = agent <- Map.get(socket.assigns.by_name, name),
         {:ok, channel} <-
           PlaybookAsk.ask(
             agent,
             PlaybookAsk.fix_request(playbook.name, socket.assigns.unreadable)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Asked @#{agent.name} to fix #{playbook.name}.")
       |> push_navigate(to: ~p"/channels/#{channel.id}")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
      _ -> {:noreply, socket}
    end
  end

  # -- The file text (last resort) --------------------------------------------------------------

  def handle_event("text_mode", _params, socket) do
    playbook = socket.assigns.playbook

    body =
      if socket.assigns.draft, do: PlaybookBuilder.text(socket.assigns.draft), else: playbook.body

    {:noreply,
     socket |> assign(:text_form, text_form(playbook, body)) |> assign(:text_body, body)}
  end

  def handle_event("text_cancel", _params, socket) do
    {:noreply, socket |> assign(:text_form, nil) |> assign(:text_body, nil)}
  end

  def handle_event("text_validate", %{"playbook" => %{"body" => body}}, socket) do
    {:noreply,
     socket
     |> assign(:text_form, text_form(socket.assigns.playbook, body, :validate))
     |> assign(:text_body, body)}
  end

  def handle_event("text_save", %{"playbook" => %{"body" => body}}, socket) do
    case Playbooks.update(socket.assigns.playbook, %{"body" => body}) do
      {:ok, playbook} ->
        {:noreply, socket |> load(playbook) |> put_flash(:info, "Saved #{playbook.name}.")}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        socket =
          socket
          |> assign(
            :text_form,
            to_form(Map.put(changeset, :action, :validate), id: "playbook-text-form")
          )
          |> assign(:text_body, body)

        if Keyword.has_key?(errors, :lock_version),
          do: {:noreply, stale(socket)},
          else: {:noreply, socket}
    end
  end

  # -- Saving ----------------------------------------------------------------------------------------

  defp save(%{assigns: %{dirty: false}} = socket), do: {:noreply, socket}

  defp save(socket) do
    %{draft: draft, playbook: playbook, parsed: parsed, problems: problems} = socket.assigns

    if problems != [] or not match?({:ok, _}, parsed) do
      {:noreply, socket}
    else
      text = PlaybookBuilder.text(draft)

      result =
        if playbook,
          do: Playbooks.update(playbook, %{"body" => text}),
          else: Playbooks.create(%{"body" => text, "source" => "user"})

      case result do
        {:ok, saved} ->
          socket =
            socket
            |> assign(:playbook, Canopy.Repo.preload(saved, :created_by, force: true))
            |> assign(:page_title, saved.name)
            |> assign(:saved_text, text)
            |> assign(:conflict, nil)
            |> assign(:editing_name, false)
            |> put_draft(PlaybookBuilder.saved(draft))

          if playbook,
            do: {:noreply, put_flash(socket, :info, "Saved #{saved.name}.")},
            else:
              {:noreply,
               socket
               |> put_flash(:info, "Created #{saved.name}.")
               |> push_patch(to: ~p"/playbooks/#{saved.id}/edit")}

        {:error, %Ecto.Changeset{errors: errors}} ->
          cond do
            Keyword.has_key?(errors, :lock_version) ->
              {:noreply, stale(socket)}

            Keyword.has_key?(errors, :name) ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "A playbook named #{draft.name} already exists; pick another name."
               )}

            true ->
              {:noreply, put_flash(socket, :error, "Could not save the playbook.")}
          end
      end
    end
  end

  defp duplicate_saved(socket) do
    case Playbooks.duplicate(socket.assigns.playbook) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Copied to #{copy.name} (disabled until you enable it).")
         |> push_navigate(to: ~p"/playbooks/#{copy.id}/edit")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not copy that playbook.")}
    end
  end

  # What the page shows, saved as a disabled copy: the draft, or the file
  # text being typed
  defp save_copy(socket) do
    with {:ok, draft} <- shown_draft(socket.assigns),
         name = Playbooks.copy_name(draft.name),
         text = PlaybookBuilder.text(%{draft | name: name}),
         {:ok, copy} <-
           Playbooks.create(%{"body" => text, "source" => "user", "enabled" => false}) do
      {:noreply,
       socket
       |> put_flash(:info, "Saved yours as #{copy.name} (disabled until you enable it).")
       |> push_navigate(to: ~p"/playbooks/#{copy.id}/edit")}
    else
      :unreadable ->
        {:noreply, put_flash(socket, :error, "Fix the file text first, then save a copy.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save a copy.")}
    end
  end

  defp shown_draft(%{text_form: form, text_body: body}) when not is_nil(form) do
    case Definition.parse(body || "") do
      {:ok, definition} -> {:ok, PlaybookBuilder.load(definition)}
      {:error, _} -> :unreadable
    end
  end

  defp shown_draft(%{draft: nil}), do: :unreadable
  defp shown_draft(%{draft: draft}), do: {:ok, draft}

  # -- Params into the draft -------------------------------------------------------------------------

  defp put_about(draft, params) do
    draft
    |> put_if(params, "title", :title)
    |> put_if(params, "description", :description)
    |> put_if(params, "guidance", :guidance)
    |> put_name(params["name"])
    |> put_inputs(params["inputs"])
    |> put_custom_nudge(params["nudge_custom"])
  end

  defp put_if(draft, params, key, field) do
    case params do
      %{^key => value} when is_binary(value) -> Map.put(draft, field, value)
      _ -> draft
    end
  end

  defp put_name(draft, nil), do: draft
  defp put_name(draft, name), do: %{draft | name: String.trim(name), name_follows_title: false}

  defp put_inputs(draft, nil), do: draft

  defp put_inputs(draft, text) do
    %{draft | inputs: if(String.trim(text) == "", do: nil, else: text)}
  end

  defp put_custom_nudge(draft, nil), do: draft

  defp put_custom_nudge(draft, text) do
    case Integer.parse(String.trim(text)) do
      {n, _} when n >= 1 and n <= 10_080 -> %{draft | stall_after: n}
      _ -> draft
    end
  end

  defp put_steps(draft, steps) when map_size(steps) == 0, do: draft

  defp put_steps(draft, steps) do
    Enum.reduce(steps, draft, fn {uid, fields}, draft ->
      PlaybookBuilder.update_step(draft, uid, fn step ->
        step =
          Enum.reduce(~w(title instructions done_when), step, fn key, step ->
            case fields do
              %{^key => value} when is_binary(value) ->
                Map.put(step, String.to_existing_atom(key), value)

              _ ->
                step
            end
          end)

        case fields do
          %{"on_reject" => to} when is_binary(to) and to != "" and not is_nil(step.on_reject) ->
            %{step | on_reject: to}

          _ ->
            step
        end
      end)
    end)
  end

  # {draft, nil | why the rename was refused}
  defp put_role(draft, %{"key" => key} = role) do
    draft =
      if is_binary(role["agent"]),
        do: PlaybookBuilder.set_role_agent(draft, key, role["agent"]),
        else: draft

    case role["name"] do
      name when is_binary(name) ->
        case PlaybookBuilder.rename_role(draft, key, name) do
          {:ok, renamed} -> {renamed, nil}
          {:error, reason} -> {draft, reason}
        end

      _ ->
        {draft, nil}
    end
  end

  defp put_role(draft, _), do: {draft, nil}

  # -- Helpers ------------------------------------------------------------------------------------------

  defp text_form(playbook, body, action \\ nil) do
    playbook
    |> Playbooks.change(%{"body" => body})
    |> Map.put(:action, action)
    |> to_form(id: "playbook-text-form")
  end

  defp undo_text(draft, %{step: step, position: position, senders: senders}) do
    case senders do
      [] ->
        "Deleted step #{position} · #{PlaybookBuilder.title(step)}."

      uids ->
        names =
          draft.steps
          |> Enum.filter(&(&1.uid in uids))
          |> Enum.map_join(" and ", &PlaybookBuilder.title/1)

        "Deleted #{PlaybookBuilder.title(step)}. #{names} no longer sends work back."
    end
  end

  defp display_title(%{draft: %{title: title, name: name}}) do
    case String.trim(title || "") do
      "" -> if name in [nil, ""], do: "Untitled playbook", else: PlaybookBuilder.humanize(name)
      title -> title
    end
  end

  defp display_title(%{playbook: %Playbook{name: name}}), do: name
  defp display_title(_), do: "Untitled playbook"

  defp lead_agent(draft, by_name), do: draft.coordinator && Map.get(by_name, draft.coordinator)

  defp role_agent(draft, key, by_name) do
    case Enum.find(draft.roles, &(&1.key == key)) do
      %{agent: name} when is_binary(name) -> Map.get(by_name, name) || %{name: name, color: nil}
      _ -> nil
    end
  end

  defp nudge_label(nil), do: "never"
  defp nudge_label(minutes), do: "after #{duration(minutes)} with no progress"

  defp duration(m) when m < 60, do: "#{m} min"
  defp duration(m) when rem(m, 60) == 0, do: "#{div(m, 60)} h"
  defp duration(m), do: "#{div(m, 60)} h #{rem(m, 60)} min"

  defp nudges, do: @nudges

  defp defaults_count(draft) do
    Enum.count(
      [
        is_nil(draft.coordinator),
        is_nil(draft.team),
        draft.channel == "current",
        draft.stall_after == Definition.default_stall_minutes(),
        is_nil(draft.inputs)
      ],
      & &1
    )
  end

  defp compact?(assigns), do: not assigns.show_all_settings and defaults_count(assigns.draft) >= 3

  defp team_size(teams, name) do
    case Enum.find(teams, &(&1.name == name)) do
      %{members: members} when is_list(members) -> length(members)
      _ -> nil
    end
  end

  defp source_label(%Playbook{source: "agent", enabled: false, created_by: %{name: name}}),
    do: "draft by @#{name}"

  defp source_label(%Playbook{source: "agent", enabled: false}), do: "agent draft"
  defp source_label(%Playbook{source: "agent", created_by: %{name: name}}), do: "by @#{name}"
  defp source_label(%Playbook{source: "agent"}), do: "by an agent"
  defp source_label(%Playbook{source: "seed"}), do: "starter"
  defp source_label(%Playbook{}), do: "yours"

  defp step_problems(problems, uid), do: Enum.filter(problems, &(&1[:uid] == uid))

  defp save_tip(assigns) do
    cond do
      assigns.problems != [] ->
        n = length(assigns.problems)
        "Fix #{n} #{if n == 1, do: "problem", else: "problems"} to save"

      not assigns.dirty ->
        "No changes to save"

      true ->
        "Save (⌘S)"
    end
  end

  defp create_tip(assigns) do
    if assigns.problems == [],
      do: "Create playbook (⌘S)",
      else: "Name the playbook and give each step a title and someone to do it"
  end

  defp second_line(step, last?) do
    cond do
      step.approval and last? -> "Waits for your approval, then the run is done."
      step.approval -> "Waits for your approval before moving on."
      String.trim(step.done_when || "") != "" -> "Done when: " <> String.trim(step.done_when)
      true -> "Done when: not set yet"
    end
  end

  defp markdown(text, by_name) do
    raw(CanopyWeb.Markdown.to_html(text || "", mentions: Map.keys(by_name), hardbreaks: false))
  end

  defp ask_fix_agent(assigns) do
    body = assigns.playbook.body

    named =
      case Regex.run(~r/^coordinator:\s*"?@?([a-z0-9][\w-]*)/m, body) do
        [_, name] -> Map.get(assigns.by_name, name)
        _ -> nil
      end

    created = assigns.playbook.created_by
    created = created && Map.get(assigns.by_name, created.name)
    named || created || List.first(assigns.active_agents)
  end

  defp owner_options(assigns, step) do
    query = String.downcase(String.trim(assigns.owner_query || ""))
    match? = fn text -> query == "" or String.contains?(String.downcase(text), query) end
    role_agents = MapSet.new(assigns.draft.roles, & &1.agent)
    role_keys = MapSet.new(assigns.draft.roles, & &1.key)

    %{
      roles: Enum.filter(assigns.draft.roles, &(match?.(&1.key) or match?.(&1.agent || ""))),
      lead: match?.("lead"),
      agents:
        Enum.filter(assigns.active_agents, fn a ->
          not MapSet.member?(role_agents, a.name) and not MapSet.member?(role_keys, a.name) and
            match?.(a.name)
        end),
      step: step
    }
  end

  # -- Render ----------------------------------------------------------------------------------------------

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
      hold={@hold}
      current_path={@current_path}
      current_channel_id={@current_channel_id}
      current_repository_id={@current_repository_id}
      palette={@palette}
      setup={@setup}
      socket={@socket}
    >
      <div
        id="playbook-builder"
        class="contents"
        phx-hook="PlaybookBuilder"
        data-dirty={to_string(unsaved?(assigns))}
        data-title={display_title(assigns)}
      >
        <.builder_header {assigns} />
        <div id="builder-scroll" class="relative flex-1 overflow-y-auto">
          <div class="mx-auto flex max-w-3xl flex-col gap-6 px-3 py-6 sm:px-6">
            <.conflict_bar :if={@conflict} conflict={@conflict} deleted={@deleted} />
            <%= cond do %>
              <% @text_form -> %>
                <.text_editor form={@text_form} />
              <% @unreadable -> %>
                <.unreadable_card reasons={@unreadable} agent={ask_fix_agent(assigns)} />
              <% true -> %>
                <.builder_body {assigns} />
            <% end %>
          </div>
        </div>
        <.undo_toast :if={@undo} undo={@undo} />
      </div>
    </Layouts.app>
    """
  end

  defp builder_header(assigns) do
    ~H"""
    <header class="sticky top-0 z-20 flex h-12 shrink-0 items-center justify-between gap-3 border-b border-base-300 bg-base-100/95 px-3 backdrop-blur sm:px-6">
      <div class="flex min-w-0 items-center gap-2.5">
        <Layouts.menu_button />
        <nav aria-label="Breadcrumb" class="flex min-w-0 items-center gap-2 text-base">
          <.link
            navigate={~p"/playbooks"}
            class="shrink-0 text-base-content/60 hover:text-base-content"
          >
            Playbooks
          </.link>
          <span class="text-base-content/30" aria-hidden="true">/</span>
          <h1
            id="builder-title"
            class={[
              "truncate font-semibold",
              is_nil(@playbook) && @draft && @draft.title == "" && "text-base-content/50"
            ]}
          >
            {display_title(assigns)}
          </h1>
        </nav>
        <span
          :if={@playbook}
          class={[
            "hidden shrink-0 rounded-full px-1.5 text-[10px] font-medium uppercase tracking-wide sm:inline",
            @playbook.source == "agent" && "bg-warning/15 text-warning",
            @playbook.source != "agent" && "bg-base-300/70 text-base-content/60"
          ]}
        >
          {source_label(@playbook)}
        </span>
        <label
          :if={@playbook && is_nil(@unreadable) && !@deleted}
          class={[
            "flex shrink-0 items-center gap-1.5 text-xs text-base-content/70",
            @dirty && "cursor-not-allowed opacity-60",
            !@dirty && "cursor-pointer"
          ]}
          title={
            if @dirty, do: "Save first", else: "Enabled playbooks are listed in every agent's prompt"
          }
        >
          <input
            type="checkbox"
            id="builder-enabled"
            class="toggle toggle-xs toggle-primary"
            checked={@playbook.enabled}
            disabled={@dirty}
            phx-click="toggle_enabled"
          /> Enabled
        </label>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <span
          :if={@playbook && is_nil(@text_form) && is_nil(@unreadable)}
          id="save-state"
          aria-live="polite"
          class={[
            "hidden text-xs sm:inline",
            @dirty && "text-warning",
            !@dirty && "text-base-content/50"
          ]}
        >
          <%= cond do %>
            <% @dirty and @problems != [] -> %>
              ● Unsaved changes · {length(@problems)} {if length(@problems) == 1,
                do: "problem",
                else: "problems"}
            <% @dirty -> %>
              ● Unsaved changes
            <% true -> %>
              ✓ Saved
          <% end %>
        </span>
        <button
          :if={@dirty && @playbook && is_nil(@text_form)}
          type="button"
          id="discard-changes"
          class="btn btn-ghost btn-sm"
          phx-click="discard"
          data-canopy-confirm="Your changes since the last save are lost."
          data-canopy-confirm-title={"Discard your changes to #{display_title(assigns)}?"}
          data-canopy-confirm-label="Discard"
        >
          Discard
        </button>
        <.row_menu
          :if={@playbook && !@deleted}
          id="builder-menu"
          label="More for this playbook"
          size="sm"
        >
          <.row_menu_item
            id="builder-duplicate"
            icon="hero-document-duplicate-mini"
            phx-click="duplicate_playbook"
            data-canopy-confirm={
              unsaved?(assigns) &&
                "The copy gets your unsaved changes; this playbook stays as it was last saved."
            }
            data-canopy-confirm-title="Duplicate with your changes?"
            data-canopy-confirm-label="Duplicate"
          >
            Duplicate
          </.row_menu_item>
          <.row_menu_item
            id="builder-export"
            icon="hero-arrow-down-tray-mini"
            href={~p"/playbooks/#{@playbook.id}/export"}
            title="Export as a file, to import on another machine"
          >
            Export file
          </.row_menu_item>
          <.row_menu_item
            :if={is_nil(@text_form)}
            id="builder-edit-text"
            icon="hero-code-bracket-mini"
            phx-click="text_mode"
            data-canopy-confirm="The file text is Markdown with settings between the --- lines at the top. A mistake there can stop the playbook from loading; the builder is the safer way to change it."
            data-canopy-confirm-title="Edit the file text?"
            data-canopy-confirm-label="Edit file text"
          >
            Edit file text
          </.row_menu_item>
          <.row_menu_item
            id="builder-delete"
            icon="hero-trash-mini"
            danger
            phx-click="delete_playbook"
            data-canopy-confirm="Finished runs keep their own copy of the text."
            data-canopy-confirm-title={"Delete #{@playbook.name}?"}
            data-canopy-confirm-label="Delete"
          >
            Delete
          </.row_menu_item>
        </.row_menu>
        <.link
          :if={@playbook && @playbook.enabled && !@dirty && !@deleted}
          navigate={~p"/playbooks/#{@playbook.id}/start"}
          id="builder-start"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-play-mini" class="size-4" /> Start a run
        </.link>
        <span
          :if={@playbook && !@deleted && (!@playbook.enabled || @dirty)}
          class="btn btn-ghost btn-sm btn-disabled hidden md:inline-flex"
          title={if @dirty, do: "Save first", else: "Enable it first"}
          aria-disabled="true"
        >
          <.icon name="hero-play-mini" class="size-4" /> Start a run
        </span>
        <.link
          :if={is_nil(@playbook) && @draft}
          navigate={~p"/playbooks"}
          id="cancel-new-playbook"
          class="btn btn-ghost btn-sm"
        >
          Cancel
        </.link>
        <button
          :if={is_nil(@text_form) && is_nil(@unreadable)}
          type="submit"
          form="builder-form"
          id="save-playbook"
          class="btn btn-primary btn-sm"
          disabled={!@dirty || @problems != [] || @deleted}
          title={if @playbook, do: save_tip(assigns), else: create_tip(assigns)}
          data-canopy-confirm={
            @playbook && @draft && @draft.name != @playbook.name &&
              "Runs in progress aren't affected."
          }
          data-canopy-confirm-title={
            @playbook && @draft && "Agents will know it as #{@draft.name} from now on."
          }
          data-canopy-confirm-label="Save"
        >
          {if @playbook, do: "Save", else: "Create playbook"}
        </button>
      </div>
    </header>
    """
  end

  attr :conflict, :string, required: true
  attr :deleted, :boolean, default: false

  defp conflict_bar(assigns) do
    ~H"""
    <div
      id="builder-conflict"
      role="alert"
      class="flex flex-wrap items-center gap-3 rounded-box border border-warning/40 bg-warning/5 px-4 py-3 text-sm"
    >
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-warning" />
      <span class="min-w-0 flex-1">{@conflict}</span>
      <.link
        :if={@deleted}
        navigate={~p"/playbooks"}
        id="leave-deleted"
        class="btn btn-ghost btn-sm"
      >
        Discard mine
      </.link>
      <button
        :if={!@deleted}
        type="button"
        id="load-theirs"
        class="btn btn-ghost btn-sm"
        phx-click="load_theirs"
      >
        Load their version
      </button>
      <button type="button" id="save-copy" class="btn btn-primary btn-sm" phx-click="save_copy">
        {if @deleted, do: "Save mine as a new playbook", else: "Save mine as a copy"}
      </button>
    </div>
    """
  end

  defp builder_body(assigns) do
    ~H"""
    <.form
      for={%{}}
      id="builder-form"
      phx-change="edit"
      phx-submit="save"
      class="flex flex-col gap-6"
      autocomplete="off"
    >
      <.draft_banner
        :if={@playbook && @playbook.source == "agent" && !@playbook.enabled}
        playbook={@playbook}
        dirty={@dirty}
      />

      <.about_card {assigns} />

      <section id="builder-steps" aria-labelledby="steps-heading" class="flex flex-col gap-2">
        <div class="flex items-center justify-between gap-3">
          <h2 id="steps-heading" class="text-sm font-semibold">
            Steps <span class="font-normal text-base-content/50">{length(@draft.steps)}</span>
          </h2>
          <p
            id="drag-announcer"
            aria-live="polite"
            class="truncate text-xs text-base-content/50 data-[active]:rounded-full data-[active]:bg-neutral data-[active]:px-3 data-[active]:py-1 data-[active]:text-neutral-content"
          >
            Drag ⋮⋮ to reorder · click a step to open it
          </p>
          <p id="drag-help" class="sr-only">
            Press Space or Enter to lift the step, the arrow keys to move it, Space or Enter to drop it, and Escape to put it back.
          </p>
        </div>
        <.problem_banner :if={@shown_problems != []} problems={@shown_problems} />
        <ol
          id="builder-step-list"
          class={["flex flex-col gap-2", @rails != %{} && "max-lg:ml-9"]}
          data-sortable
        >
          <.step_row
            :for={{step, i} <- Enum.with_index(@draft.steps)}
            step={step}
            index={i}
            total={length(@draft.steps)}
            open={MapSet.member?(@open, step.uid)}
            rails={Map.get(@rails, step.uid, [])}
            problems={step_problems(@shown_problems, step.uid)}
            draft={@draft}
            by_name={@by_name}
            popover={@popover}
            active_agents={@active_agents}
            owner_query={@owner_query}
            key_error={@key_error}
            saved={!is_nil(@playbook)}
          />
        </ol>
        <div class="relative">
          <button
            type="button"
            id="add-step"
            class="btn btn-sm w-full border-dashed border-base-300 bg-transparent font-normal text-base-content/70 hover:border-primary/50 hover:bg-primary/5"
            phx-click="popover"
            phx-value-id={"add:#{length(@draft.steps)}"}
            disabled={length(@draft.steps) >= PlaybookBuilder.max_steps()}
            title={
              length(@draft.steps) >= PlaybookBuilder.max_steps() &&
                "Playbooks can have up to 20 steps"
            }
          >
            <.icon name="hero-plus-mini" class="size-4" /> Add step
          </button>
          <%!-- opens upward: the bottom of the list is often the bottom of the window --%>
          <.add_menu
            :if={@popover == "add:#{length(@draft.steps)}"}
            index={length(@draft.steps)}
            class="bottom-full mb-1"
          />
        </div>
      </section>

      <.notes_line :if={@draft.notes != []} notes={@draft.notes} />

      <.guidance_card {assigns} />

      <p :if={@playbook} class="text-center text-xs text-base-content/50">
        Saved as <span class="font-mono">{@playbook.name}.md</span>
        · <a href={~p"/playbooks/#{@playbook.id}/export"} class="link">Export file</a>
      </p>
    </.form>
    """
  end

  attr :playbook, :any, required: true
  attr :dirty, :boolean, required: true

  defp draft_banner(assigns) do
    ~H"""
    <div
      id="draft-banner"
      class="flex flex-wrap items-start gap-3 rounded-box border border-warning/40 bg-warning/5 px-4 py-3"
    >
      <.avatar :if={@playbook.created_by} agent={@playbook.created_by} size="size-7" />
      <div class="min-w-0 flex-1">
        <p class="text-sm font-semibold">
          {if @playbook.created_by, do: "@#{@playbook.created_by.name}", else: "An agent"} drafted this playbook
          <span class="font-normal text-base-content/50">
            · {Canopy.Schedules.relative(@playbook.updated_at)}
          </span>
        </p>
        <p class="text-xs text-base-content/70">
          Agents can't use it until you enable it. Read the steps through and change anything you like first.
        </p>
      </div>
      <div class="flex items-center gap-2">
        <button
          type="button"
          id="delete-draft"
          class="btn btn-ghost btn-sm"
          phx-click="delete_playbook"
          data-canopy-confirm="The agent can draft it again if you ask."
          data-canopy-confirm-title={"Delete #{@playbook.name}?"}
          data-canopy-confirm-label="Delete draft"
        >
          Delete draft
        </button>
        <button
          type="button"
          id="enable-draft"
          class="btn btn-primary btn-sm"
          phx-click="toggle_enabled"
          disabled={@dirty}
          title={@dirty && "Save first"}
        >
          Enable playbook
        </button>
      </div>
    </div>
    """
  end

  defp about_card(assigns) do
    ~H"""
    <section id="about-card" class="rounded-box border border-base-300 bg-base-200 p-5 sm:p-6">
      <label for="about-title" class="sr-only">Name</label>
      <input
        id="about-title"
        name="title"
        type="text"
        value={@draft.title}
        placeholder="Name your playbook"
        phx-debounce="250"
        maxlength="120"
        class="w-full border-0 bg-transparent p-0 text-2xl font-semibold outline-none placeholder:text-base-content/35 focus:ring-0"
      />
      <div class="mt-1 flex flex-wrap items-center gap-1 text-xs text-base-content/55">
        <%= if @editing_name do %>
          <label for="about-name">Agents know it as</label>
          <input
            id="about-name"
            name="name"
            type="text"
            value={@draft.name}
            phx-debounce="blur"
            class="input input-xs w-48 font-mono"
          />
          <span :if={@playbook && @draft.name != @playbook.name} class="text-warning">
            Agents will know it as <span class="font-mono">{@draft.name}</span>
            from now on. Runs in progress aren't affected.
          </span>
        <% else %>
          <%= if @draft.name == "" do %>
            Agents will know it by a short name made from this.
          <% else %>
            Agents know it as
            <button
              type="button"
              id="edit-name"
              class="font-mono hover:text-base-content hover:underline"
              phx-click="edit_name"
              title="Change the name agents use"
            >
              {@draft.name}
            </button>
          <% end %>
        <% end %>
      </div>

      <div class="relative mt-4">
        <label for="about-description" class="sr-only">Description</label>
        <textarea
          id="about-description"
          name="description"
          rows="2"
          phx-debounce="250"
          maxlength="240"
          placeholder="When should someone use it? One sentence…"
          class="textarea auto-grow w-full min-h-16 resize-none text-[15px] leading-relaxed"
        >{@draft.description}</textarea>
        <span
          :if={String.length(@draft.description || "") >= 160}
          id="description-count"
          class={[
            "absolute bottom-2 right-3 text-[11px]",
            String.length(@draft.description) > 200 && "text-error",
            String.length(@draft.description) <= 200 && "text-base-content/50"
          ]}
        >
          {String.length(@draft.description)}/200
        </span>
      </div>

      <dl class="mt-5 grid gap-x-4 gap-y-3 text-sm md:grid-cols-[132px_1fr] md:items-center">
        <%= if !compact?(assigns) or @draft.coordinator do %>
          <dt class="text-base-content/55">Led by</dt>
          <dd class="relative">
            <button
              type="button"
              id="setting-lead"
              class={[
                setting_button(),
                @popover == "lead" && "border-primary/60 ring-2 ring-primary/15"
              ]}
              phx-click="popover"
              phx-value-id="lead"
              aria-haspopup="listbox"
              aria-expanded={to_string(@popover == "lead")}
            >
              <%= if agent = lead_agent(@draft, @by_name) do %>
                <.avatar agent={agent} /> <span class="font-medium">@{agent.name}</span>
              <% else %>
                <span :if={@draft.coordinator} class="font-medium">@{@draft.coordinator}</span>
                <span :if={!@draft.coordinator} class="text-base-content/60">Choose when starting</span>
              <% end %>
              <.icon name="hero-chevron-down-micro" class="size-3 text-base-content/40" />
            </button>
            <.lead_popover :if={@popover == "lead"} draft={@draft} agents={@active_agents} />
          </dd>
        <% end %>

        <%= if !compact?(assigns) or @draft.team do %>
          <dt class="text-base-content/55">Team</dt>
          <dd class="relative">
            <button
              type="button"
              id="setting-team"
              class={[
                setting_button(),
                @popover == "team" && "border-primary/60 ring-2 ring-primary/15"
              ]}
              phx-click="popover"
              phx-value-id="team"
              aria-haspopup="listbox"
            >
              <%= if @draft.team do %>
                <span class="font-medium">@{@draft.team}</span>
                <span :if={team_size(@teams, @draft.team)} class="text-base-content/50">
                  · {team_size(@teams, @draft.team)} agents
                </span>
              <% else %>
                <span class="text-base-content/60">No team</span>
              <% end %>
              <.icon name="hero-chevron-down-micro" class="size-3 text-base-content/40" />
            </button>
            <.team_popover :if={@popover == "team"} draft={@draft} teams={@teams} />
          </dd>
        <% end %>

        <%= if !compact?(assigns) or @draft.channel == "new" do %>
          <dt class="text-base-content/55">Runs in</dt>
          <dd>
            <div class="join" role="group" aria-label="Runs in">
              <button
                type="button"
                id="runs-in-new"
                class={[
                  "btn join-item btn-sm border-base-300",
                  @draft.channel == "new" && "btn-active bg-base-200 font-medium shadow-sm",
                  @draft.channel != "new" && "bg-base-100 font-normal text-base-content/70"
                ]}
                aria-pressed={to_string(@draft.channel == "new")}
                phx-click="set_channel"
                phx-value-value="new"
              >
                A new channel
              </button>
              <button
                type="button"
                id="runs-in-current"
                class={[
                  "btn join-item btn-sm border-base-300",
                  @draft.channel == "current" && "btn-active bg-base-200 font-medium shadow-sm",
                  @draft.channel != "current" && "bg-base-100 font-normal text-base-content/70"
                ]}
                aria-pressed={to_string(@draft.channel == "current")}
                phx-click="set_channel"
                phx-value-value="current"
              >
                The channel it's started from
              </button>
            </div>
          </dd>
        <% end %>

        <%= if !compact?(assigns) or @draft.stall_after != Definition.default_stall_minutes() do %>
          <dt class="text-base-content/55">Nudge the lead</dt>
          <dd class="relative">
            <button
              type="button"
              id="setting-nudge"
              class={[
                setting_button(),
                @popover == "nudge" && "border-primary/60 ring-2 ring-primary/15"
              ]}
              phx-click="popover"
              phx-value-id="nudge"
              aria-haspopup="listbox"
            >
              {nudge_label(@draft.stall_after)}
              <.icon name="hero-chevron-down-micro" class="size-3 text-base-content/40" />
            </button>
            <.nudge_popover :if={@popover == "nudge"} draft={@draft} />
          </dd>
        <% end %>

        <%= if !compact?(assigns) or @draft.inputs do %>
          <dt class="self-start pt-1.5 text-base-content/55">Ask when starting</dt>
          <dd class="relative min-w-0">
            <button
              type="button"
              id="setting-inputs"
              class={[
                @draft.inputs && [setting_button(), "w-full justify-start"],
                !@draft.inputs &&
                  "btn btn-ghost btn-sm border-dashed border-base-content/30 font-normal text-base-content/60",
                @popover == "inputs" && "border-primary/60 ring-2 ring-primary/15"
              ]}
              phx-click="popover"
              phx-value-id="inputs"
            >
              <span :if={@draft.inputs} class="truncate">{@draft.inputs}</span>
              <span :if={!@draft.inputs}>+ Add a hint for the brief</span>
            </button>
            <div
              :if={@popover == "inputs"}
              id="inputs-popover"
              role="dialog"
              aria-label="Ask when starting"
              class="pop absolute left-0 top-full z-30 mt-1 w-full rounded-box border border-base-300 bg-base-200 p-3"
              phx-click-away="close_popover"
              phx-window-keydown="close_popover"
              phx-key="Escape"
            >
              <label for="inputs-text" class="text-xs text-base-content/60">
                Shown under "What's this run about?" when someone starts a run
              </label>
              <textarea
                id="inputs-text"
                name="inputs"
                rows="3"
                phx-debounce="250"
                class="textarea auto-grow mt-1 w-full text-sm"
                placeholder="e.g. The symptom, where it happens, steps to reproduce…"
              >{@draft.inputs}</textarea>
              <div class="mt-2 flex justify-end">
                <button type="button" class="btn btn-sm" phx-click="close_popover">Done</button>
              </div>
            </div>
          </dd>
        <% end %>

        <dt class="self-start pt-1 text-base-content/55">Roles</dt>
        <dd class="flex flex-wrap items-center gap-1.5">
          <span :if={@draft.roles == []} class="text-xs text-base-content/50">
            Added as you choose who does each step
          </span>
          <div :for={role <- @draft.roles} class="relative">
            <button
              type="button"
              id={"role-chip-#{role.key}"}
              class={[
                "inline-flex items-center gap-1.5 rounded-full border border-base-300 bg-base-100 py-0.5 pl-0.5 pr-2.5 text-[13px] hover:border-base-content/25",
                @popover == "role:" <> role.key && "border-primary/60 ring-2 ring-primary/15"
              ]}
              phx-click="popover"
              phx-value-id={"role:" <> role.key}
            >
              <.avatar agent={role_agent(@draft, role.key, @by_name)} />
              <span class="font-medium">{PlaybookBuilder.humanize(role.key)}</span>
              <span :if={role.agent} class="text-base-content/50">@{role.agent}</span>
            </button>
            <.role_popover
              :if={@popover == "role:" <> role.key}
              role={role}
              draft={@draft}
              agents={@active_agents}
              teams={@teams}
              error={@key_error}
            />
          </div>
          <button
            type="button"
            id="add-role"
            class="rounded-full border border-dashed border-base-300 px-2.5 py-0.5 text-[13px] text-base-content/60 hover:border-primary/50 hover:text-base-content"
            phx-click="add_role"
          >
            + Role
          </button>
        </dd>
      </dl>
      <button
        :if={compact?(assigns)}
        type="button"
        id="more-settings"
        class="mt-3 text-xs text-base-content/55 hover:text-base-content hover:underline"
        phx-click="more_settings"
      >
        More settings
      </button>
    </section>
    """
  end

  defp setting_button,
    do:
      "inline-flex max-w-full items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-2.5 py-1 text-sm hover:border-base-content/25"

  attr :draft, :map, required: true
  attr :agents, :list, required: true

  defp lead_popover(assigns) do
    # the current lead first, then everyone else in sidebar order
    {current, others} =
      assigns.agents
      |> Agents.grouped()
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.split_with(&(&1.name == assigns.draft.coordinator))

    assigns = assign(assigns, current: current, others: others)

    ~H"""
    <div
      id="lead-popover"
      role="dialog"
      aria-label="Who leads a run"
      class="pop absolute left-0 top-full z-30 mt-1 w-[360px] max-w-[90vw] rounded-box border border-base-300 bg-base-200 p-1.5"
      phx-click-away="close_popover"
      phx-window-keydown="close_popover"
      phx-key="Escape"
    >
      <div class="px-2.5 pb-2 pt-1.5">
        <p class="text-sm font-semibold">Who leads a run</p>
        <p class="mt-0.5 text-xs text-base-content/60">
          The lead starts the run, hands each step to whoever does it, checks "Done when", and moves the run along. It also does the steps marked Lead.
        </p>
      </div>
      <ul role="listbox" aria-label="Lead" class="max-h-72 overflow-y-auto" data-popover-list>
        <%= for agent <- @current do %>
          <.lead_option agent={agent} selected />
          <li role="separator" class="my-1 h-px bg-base-300"></li>
        <% end %>
        <.lead_option :for={agent <- @others} agent={agent} selected={false} />
      </ul>
      <%!-- the one choice that isn't an agent stays in view below the scrolling list --%>
      <div class="mt-1 border-t border-base-300 pt-1">
        <button
          type="button"
          id="lead-option-none"
          aria-pressed={to_string(is_nil(@draft.coordinator))}
          class={[popover_item(), is_nil(@draft.coordinator) && "bg-base-100"]}
          phx-click="set_lead"
          phx-value-name=""
        >
          <span class="flex size-5 shrink-0 items-center justify-center rounded-full border border-dashed border-base-content/40 text-[11px] text-base-content/60">?</span>
          <span class="flex-1 font-medium">Choose when starting</span>
          <.icon
            :if={is_nil(@draft.coordinator)}
            name="hero-check-mini"
            class="ml-auto size-4 text-primary"
          />
        </button>
      </div>
      <p class="mt-1 border-t border-base-300 px-2.5 pb-1 pt-2 text-[11px] text-base-content/55">
        You can pick a different lead each time you start a run. When an agent starts it, that agent leads.
      </p>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :selected, :boolean, required: true

  defp lead_option(assigns) do
    ~H"""
    <li role="option" aria-selected={to_string(@selected)}>
      <button
        type="button"
        id={"lead-option-#{@agent.name}"}
        class={[popover_item(), @selected && "bg-base-100"]}
        phx-click="set_lead"
        phx-value-name={@agent.name}
      >
        <.avatar agent={@agent} />
        <span class="min-w-0 flex-1">
          <span class="font-medium">@{@agent.name}</span>
          <span :if={@agent.role} class="block truncate text-xs text-base-content/55">{@agent.role}</span>
        </span>
        <.icon :if={@selected} name="hero-check-mini" class="ml-auto size-4 text-primary" />
      </button>
    </li>
    """
  end

  attr :draft, :map, required: true
  attr :teams, :list, required: true

  defp team_popover(assigns) do
    ~H"""
    <div
      id="team-popover"
      role="dialog"
      aria-label="Team"
      class="pop absolute left-0 top-full z-30 mt-1 w-72 rounded-box border border-base-300 bg-base-200 p-1.5"
      phx-click-away="close_popover"
      phx-window-keydown="close_popover"
      phx-key="Escape"
    >
      <p class="px-2.5 pb-1 pt-1.5 text-xs text-base-content/60">
        A team's members fill roles by their role labels when a run starts, and join the run's channel.
      </p>
      <ul role="listbox" aria-label="Team" data-popover-list>
        <li :for={team <- @teams} role="option" aria-selected={to_string(@draft.team == team.name)}>
          <button
            type="button"
            id={"team-option-#{team.name}"}
            class={popover_item()}
            phx-click="set_team"
            phx-value-name={team.name}
          >
            <span class="flex-1"><span class="font-medium">@{team.name}</span>
            <span class="text-base-content/50">· {length(team.members)} agents</span></span>
            <.icon :if={@draft.team == team.name} name="hero-check-mini" class="size-4 text-primary" />
          </button>
        </li>
        <li role="option" aria-selected={to_string(is_nil(@draft.team))}>
          <button
            type="button"
            id="team-option-none"
            class={popover_item()}
            phx-click="set_team"
            phx-value-name=""
          >
            <span class="flex-1 font-medium">No team</span>
            <.icon :if={is_nil(@draft.team)} name="hero-check-mini" class="size-4 text-primary" />
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :draft, :map, required: true

  defp nudge_popover(assigns) do
    assigns = assign(assigns, :nudges, nudges())

    ~H"""
    <div
      id="nudge-popover"
      role="dialog"
      aria-label="Nudge the lead"
      class="pop absolute left-0 top-full z-30 mt-1 w-64 rounded-box border border-base-300 bg-base-200 p-1.5"
      phx-click-away="close_popover"
      phx-window-keydown="close_popover"
      phx-key="Escape"
    >
      <p class="px-2.5 pb-1 pt-1.5 text-xs text-base-content/60">
        When a step goes quiet this long, Canopy nudges the lead.
      </p>
      <ul role="listbox" aria-label="Nudge after" data-popover-list>
        <li
          :for={{minutes, label} <- @nudges}
          role="option"
          aria-selected={to_string(@draft.stall_after == minutes)}
        >
          <button
            type="button"
            id={"nudge-#{minutes}"}
            class={popover_item()}
            phx-click="set_nudge"
            phx-value-minutes={minutes}
          >
            <span class="flex-1">{label}</span>
            <.icon
              :if={@draft.stall_after == minutes}
              name="hero-check-mini"
              class="size-4 text-primary"
            />
          </button>
        </li>
        <li role="option" aria-selected={to_string(is_nil(@draft.stall_after))}>
          <button
            type="button"
            id="nudge-never"
            class={popover_item()}
            phx-click="set_nudge"
            phx-value-minutes=""
          >
            <span class="flex-1">Never</span>
            <.icon
              :if={is_nil(@draft.stall_after)}
              name="hero-check-mini"
              class="size-4 text-primary"
            />
          </button>
        </li>
      </ul>
      <div class="flex items-center gap-2 border-t border-base-300 px-2.5 pb-1 pt-2 text-xs">
        <label for="nudge-custom" class="text-base-content/60">Custom</label>
        <input
          id="nudge-custom"
          name="nudge_custom"
          type="number"
          min="1"
          max="10080"
          phx-debounce="400"
          value={@draft.stall_after}
          class="input input-xs w-20"
        />
        <span class="text-base-content/60">min</span>
      </div>
    </div>
    """
  end

  attr :role, :map, required: true
  attr :draft, :map, required: true
  attr :agents, :list, required: true
  attr :teams, :list, required: true
  attr :error, :string, default: nil

  defp role_popover(assigns) do
    assigns =
      assigns
      |> assign(:uses, PlaybookBuilder.role_uses(assigns.draft, assigns.role.key))
      |> assign(:team_member, team_member(assigns.teams, assigns.draft.team, assigns.role.key))

    ~H"""
    <div
      id="role-popover"
      role="dialog"
      aria-label={"Role #{PlaybookBuilder.humanize(@role.key)}"}
      class="pop absolute left-0 top-full z-30 mt-1 w-80 max-w-[90vw] rounded-box border border-base-300 bg-base-200 p-3"
      phx-click-away="close_popover"
      phx-window-keydown="close_popover"
      phx-key="Escape"
    >
      <input type="hidden" name="role[key]" value={@role.key} />
      <label for="role-name" class="text-xs font-medium text-base-content/60">Name</label>
      <input
        id="role-name"
        name="role[name]"
        type="text"
        value={@role.key}
        phx-debounce="blur"
        class={["input input-sm mt-1 w-full", @error && "input-error"]}
        aria-describedby={@error && "role-name-error"}
      />
      <p :if={@error} id="role-name-error" class="mt-1 text-xs text-error">{@error}</p>
      <p class="mt-3 text-xs font-medium text-base-content/60">Who fills it when a run starts</p>
      <ol class="mt-1 flex flex-col gap-1.5 text-sm">
        <li :if={@draft.team} class="flex gap-2">
          <span class="text-base-content/50">1.</span>
          <span>
            The @{@draft.team} member labelled "{@role.key}":
            <span class="font-medium">{(@team_member && "@" <> @team_member.name) || "nobody yet"}</span>
          </span>
        </li>
        <li class="flex items-center gap-2">
          <span :if={@draft.team} class="text-base-content/50">2.</span>
          <label for="role-agent" class="shrink-0">{if @draft.team, do: "Otherwise", else: "Filled by"}</label>
          <select id="role-agent" name="role[agent]" class="select select-sm min-w-0 flex-1">
            <option value="" selected={is_nil(@role.agent)}>No agent</option>
            <option :for={a <- @agents} value={a.name} selected={@role.agent == a.name}>
              @{a.name}
            </option>
          </select>
        </li>
      </ol>
      <p class="mt-2 text-[11px] text-base-content/55">
        You can still swap anyone in when you start a run.
      </p>
      <p :if={@uses != []} class="mt-2 text-xs text-base-content/60">
        Used in
        <%= for {{n, step}, i} <- Enum.with_index(@uses) do %>
          {if i > 0, do: " and "}<button
            type="button"
            class="link"
            phx-click="goto"
            phx-value-uid={step.uid}
          >{n} · {PlaybookBuilder.title(step)}</button>
        <% end %>
      </p>
      <div class="mt-3 flex justify-between">
        <button
          type="button"
          id="remove-role"
          class="btn btn-ghost btn-xs text-error"
          phx-click="remove_role"
          phx-value-key={@role.key}
          disabled={@uses != []}
          title={
            @uses != [] &&
              "Take it off #{if length(@uses) == 1, do: "its step", else: "those steps"} first"
          }
        >
          Remove role
        </button>
        <button type="button" class="btn btn-sm" phx-click="close_popover">Done</button>
      </div>
    </div>
    """
  end

  defp team_member(_teams, nil, _role), do: nil

  defp team_member(teams, team_name, role) do
    case Enum.find(teams, &(&1.name == team_name)) do
      nil ->
        nil

      team ->
        labels = Teams.member_roles(team)
        members = Teams.active_members(team)
        Enum.find(members, &(labels[&1.id] == role)) || Enum.find(members, &(&1.name == role))
    end
  end

  defp popover_item,
    do:
      "flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-sm hover:bg-base-100 focus:bg-base-100 focus:outline-none"

  attr :problems, :list, required: true

  defp problem_banner(assigns) do
    ~H"""
    <div
      id="problem-banner"
      role="alert"
      class="rounded-box border border-error/30 bg-error/5 px-4 py-3"
    >
      <p class="flex items-center gap-2 text-sm font-medium text-error">
        <span class="flex size-5 items-center justify-center rounded-full bg-error text-[11px] font-semibold text-error-content">
          {length(@problems)}
        </span>
        {if length(@problems) == 1,
          do: "1 thing to fix before you can save",
          else: "#{length(@problems)} things to fix before you can save"}
      </p>
      <ul class="mt-2 flex flex-col gap-1 pl-7 text-sm">
        <li :for={problem <- @problems} class="text-base-content/80">
          <button
            :if={problem[:uid] && problem[:where]}
            type="button"
            class="link link-error font-medium"
            phx-click="goto"
            phx-value-uid={problem.uid}
          >
            {problem.where}
          </button>
          <button
            :if={problem[:role]}
            type="button"
            class="link link-error font-medium"
            phx-click="popover"
            phx-value-id={"role:" <> problem.role}
          >
            {problem.where}
          </button>
          <%= if problem[:where] do %>
            — {problem.detail}
          <% else %>
            {problem.text}
          <% end %>
        </li>
      </ul>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :total, :integer, required: true
  attr :open, :boolean, required: true
  attr :rails, :list, required: true
  attr :problems, :list, required: true
  attr :draft, :map, required: true
  attr :by_name, :map, required: true
  attr :popover, :any, required: true
  attr :active_agents, :list, required: true
  attr :owner_query, :string, default: ""
  attr :key_error, :any, default: nil

  attr :saved, :boolean,
    default: true,
    doc: "false until the playbook's first save; hides the new badge"

  defp step_row(assigns) do
    step = assigns.step
    targets = PlaybookBuilder.send_back_targets(assigns.draft, step.uid)
    target = step.on_reject && Enum.find(assigns.draft.steps, &(&1.id == step.on_reject))

    assigns =
      assigns
      |> assign(:n, assigns.index + 1)
      |> assign(:last?, assigns.index + 1 == assigns.total)
      |> assign(:targets, targets)
      |> assign(:target, target)
      |> assign(:send_back_problem, Enum.find(assigns.problems, &(&1[:kind] == :send_back)))
      |> assign(:owner_problem, Enum.any?(assigns.problems, &(&1[:kind] == :owner)))

    ~H"""
    <li
      id={"step-#{@step.uid}"}
      data-uid={@step.uid}
      data-step-id={@step.id}
      data-on-reject={@step.on_reject}
      data-title={PlaybookBuilder.title(@step)}
      class={[
        "group/step relative rounded-box border bg-base-200 transition-colors",
        @problems != [] && "border-error/60 ring-2 ring-error/10",
        @problems == [] && @open && "border-primary/50 ring-2 ring-primary/15",
        @problems == [] && !@open && @step.approval && "border-warning/40",
        @problems == [] && !@open && !@step.approval && "border-base-300 hover:border-base-content/25"
      ]}
    >
      <span
        :for={rail <- @rails}
        class={["rail", "rail-#{rail.kind}"]}
        style={"--lane: #{rail.lane}"}
        aria-hidden="true"
      ></span>
      <p
        :for={rail <- Enum.filter(@rails, &(&1.kind == :start))}
        class="absolute right-[calc(100%+34px)] top-1/2 hidden w-32 -translate-y-1/2 text-right text-[11px] leading-snug text-secondary lg:block"
        style={"margin-right: #{rail.lane * 10}px"}
      >
        {rail.label}
      </p>

      <%!-- the gap above: "+ Add step here" --%>
      <div
        :if={@index > 0}
        class="absolute -top-[9px] left-10 right-10 z-10 flex h-2.5 items-center opacity-0 transition-opacity hover:opacity-100 focus-within:opacity-100"
      >
        <div class="h-px flex-1 bg-primary/50"></div>
        <button
          type="button"
          id={"add-step-at-#{@index}"}
          class="rounded-full border border-primary/40 bg-base-100 px-2 text-[11px] text-primary"
          phx-click="popover"
          phx-value-id={"add:#{@index}"}
          disabled={@total >= PlaybookBuilder.max_steps()}
          title={@total >= PlaybookBuilder.max_steps() && "Playbooks can have up to 20 steps"}
        >
          + Add step here
        </button>
        <div class="h-px flex-1 bg-primary/50"></div>
      </div>
      <.add_menu :if={@popover == "add:#{@index}"} index={@index} class="top-1" />

      <div class="flex items-center gap-3 py-2.5 pl-2 pr-3">
        <button
          type="button"
          id={"grip-#{@step.uid}"}
          class="grip cursor-grab touch-none rounded px-1 py-1 text-base-content/30 hover:text-base-content/60 focus:text-base-content/70 active:cursor-grabbing"
          aria-label={"Move step #{@n}, #{PlaybookBuilder.title(@step)}"}
          aria-describedby="drag-help"
          data-grip
        >
          <svg viewBox="0 0 8 14" class="h-3.5 w-2" aria-hidden="true" fill="currentColor">
            <circle cx="2" cy="2" r="1.2" /><circle cx="6" cy="2" r="1.2" />
            <circle cx="2" cy="7" r="1.2" /><circle cx="6" cy="7" r="1.2" />
            <circle cx="2" cy="12" r="1.2" /><circle cx="6" cy="12" r="1.2" />
          </svg>
        </button>
        <span
          data-number
          class={[
            "flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
            @open && "bg-primary text-primary-content",
            !@open && "bg-base-100 text-base-content/70"
          ]}
        >
          {@n}
        </span>

        <%= if @open do %>
          <div class="flex min-w-0 flex-1 items-center gap-2">
            <label for={"step-#{@step.uid}-title"} class="sr-only">Step {@n} title</label>
            <input
              id={"step-#{@step.uid}-title"}
              name={"steps[#{@step.uid}][title]"}
              type="text"
              value={@step.title}
              phx-debounce="250"
              maxlength="200"
              placeholder={
                if @index == 0,
                  do: "What happens first? e.g. 'Triage and scope'",
                  else: "What happens in this step?"
              }
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-[15px] font-medium outline-none placeholder:font-normal placeholder:text-base-content/40 focus:ring-0"
            />
            <.step_badges
              step={@step}
              target={@target}
              send_back_problem={@send_back_problem}
              saved={@saved}
            />
          </div>
          <button
            type="button"
            class="rounded p-1 text-base-content/40 hover:text-base-content"
            phx-click="toggle_step"
            phx-value-uid={@step.uid}
            aria-label={"Close step #{@n}"}
            aria-expanded="true"
          >
            <.icon name="hero-chevron-up-micro" class="size-4" />
          </button>
        <% else %>
          <button
            type="button"
            id={"open-step-#{@step.uid}"}
            class="flex min-w-0 flex-1 items-center gap-3 text-left"
            phx-click="toggle_step"
            phx-value-uid={@step.uid}
            aria-expanded="false"
          >
            <span class="min-w-0 flex-1">
              <span class="flex flex-wrap items-center gap-2">
                <span class={["font-medium", String.trim(@step.title) == "" && "text-base-content/45"]}>
                  {PlaybookBuilder.title(@step)}
                </span>
                <.step_badges
                  step={@step}
                  target={@target}
                  send_back_problem={@send_back_problem}
                  saved={@saved}
                />
              </span>
              <span class="block truncate text-xs text-base-content/50">{second_line(@step, @last?)}</span>
            </span>
            <span class="flex shrink-0 items-center gap-3 text-[13px] text-base-content/70">
              <span
                :if={@owner_problem}
                class="rounded-md border border-dashed border-error/60 px-2 py-0.5 text-xs text-error"
              >
                + Who does it?
              </span>
              <span :for={owner <- @step.owner} class="flex items-center gap-1.5">
                <.owner_avatar owner={owner} draft={@draft} by_name={@by_name} />
                <span class="max-md:hidden">{PlaybookBuilder.humanize(owner)}</span>
              </span>
            </span>
            <.icon name="hero-chevron-down-micro" class="size-4 shrink-0 text-base-content/35" />
          </button>
        <% end %>
      </div>

      <div
        :for={problem <- @problems}
        :if={problem[:kind] in [:send_back]}
        class="flex flex-wrap items-center gap-2 border-t border-error/20 bg-error/5 px-4 py-2 text-sm text-error"
      >
        <.icon name="hero-exclamation-triangle-mini" class="size-4 shrink-0" />
        <span class="min-w-0 flex-1">{problem.text}</span>
        <button
          :for={{label, event, params} <- problem.fixes}
          type="button"
          class="btn btn-xs border-error/30 bg-base-100 font-normal"
          phx-click={event}
          phx-value-uid={params["uid"]}
          phx-value-to={params["to"]}
        >
          {label}
        </button>
      </div>

      <.step_editor :if={@open} {assigns} />
    </li>
    """
  end

  attr :step, :map, required: true
  attr :target, :any, required: true
  attr :send_back_problem, :any, required: true
  attr :saved, :boolean, required: true

  defp step_badges(assigns) do
    ~H"""
    <span
      :if={length(@step.owner) > 1}
      class="rounded-full bg-base-100 px-2 py-0.5 text-[11px] text-base-content/60"
    >
      in parallel
    </span>
    <span
      :if={@step.on_reject}
      class={[
        "rounded-full px-2 py-0.5 text-[11px] font-medium",
        @send_back_problem && "bg-error/10 text-error",
        !@send_back_problem && "bg-secondary/10 text-secondary"
      ]}
    >
      ↩︎ can send back to {(@target && PlaybookBuilder.title(@target)) || @step.on_reject}{if @send_back_problem,
        do: " ⚠"}
    </span>
    <span
      :if={@step.approval}
      class="rounded-full bg-warning/10 px-2 py-0.5 text-[11px] font-medium text-warning"
    >
      waits for you
    </span>
    <span
      :if={@step.optional}
      class="rounded-full border border-dashed border-base-300 px-2 py-0.5 text-[11px] text-base-content/60"
    >
      can be skipped
    </span>
    <span
      :if={@step.fresh && @saved}
      class="rounded-full bg-primary/10 px-2 py-0.5 text-[11px] font-medium text-primary"
    >
      new
    </span>
    """
  end

  defp step_editor(assigns) do
    ~H"""
    <div class="flex flex-col gap-5 border-t border-base-300/70 pb-4 pl-4 pr-4 pt-4 sm:pl-[58px]">
      <%!-- Who does it --%>
      <div>
        <p class="mb-1.5 text-xs font-semibold text-base-content/70">Who does it</p>
        <div class="flex flex-wrap items-center gap-1.5">
          <span
            :for={owner <- @step.owner}
            class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 py-0.5 pl-1 pr-1 text-[13px]"
          >
            <.owner_avatar owner={owner} draft={@draft} by_name={@by_name} />
            <span class="font-medium">{PlaybookBuilder.humanize(owner)}</span>
            <span class="text-base-content/50">{owner_agent_label(owner, @draft)}</span>
            <button
              type="button"
              class="rounded px-1 text-base-content/40 hover:text-error"
              phx-click="toggle_owner"
              phx-value-uid={@step.uid}
              phx-value-role={owner}
              aria-label={"Remove #{PlaybookBuilder.humanize(owner)} from this step"}
            >
              ×
            </button>
          </span>
          <div class="relative">
            <button
              type="button"
              id={"add-owner-#{@step.uid}"}
              class={[
                "rounded-lg border px-2.5 py-0.5 text-[13px]",
                @owner_problem && "border-dashed border-error/60 text-error",
                @step.owner == [] && !@owner_problem &&
                  "border-dashed border-base-content/30 text-base-content/60 hover:border-primary/50",
                @step.owner != [] && "border-primary/40 text-primary hover:bg-primary/5",
                @popover == "owner:" <> @step.uid && "ring-2 ring-primary/15"
              ]}
              phx-click="popover"
              phx-value-id={"owner:" <> @step.uid}
              aria-haspopup="listbox"
            >
              {if @step.owner == [], do: "+ Pick an agent or role", else: "+ Add someone"}
            </button>
            <.owner_picker
              :if={@popover == "owner:" <> @step.uid}
              options={owner_options(assigns, @step)}
              draft={@draft}
              by_name={@by_name}
            />
          </div>
          <button
            :if={@step.owner == []}
            type="button"
            class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 py-0.5 pl-1 pr-2.5 text-[13px] text-base-content/70 hover:border-base-content/25"
            phx-click="toggle_owner"
            phx-value-uid={@step.uid}
            phx-value-role="coordinator"
          >
            <.owner_avatar owner="coordinator" draft={@draft} by_name={@by_name} /> The lead does it
          </button>
        </div>
        <p :if={length(@step.owner) > 1} class="mt-1.5 text-xs text-base-content/55">
          Two or more people work on this step at the same time. The lead only gives it to the ones it needs.
        </p>
      </div>

      <%!-- What should happen --%>
      <div>
        <div class="mb-1.5 flex items-baseline justify-between gap-3">
          <label
            for={"step-#{@step.uid}-instructions"}
            class="text-xs font-semibold text-base-content/70"
          >
            What should happen
          </label>
          <span class="text-[11px] text-base-content/45">The lead reads this when the run reaches this step</span>
        </div>
        <.md_field
          id={"step-#{@step.uid}-instructions"}
          name={"steps[#{@step.uid}][instructions]"}
          value={@step.instructions}
          by_name={@by_name}
          placeholder="Tell the lead what this step is for and how to hand it out. Write it like a note to a colleague."
        />
      </div>

      <%!-- Done when --%>
      <div>
        <label
          for={"step-#{@step.uid}-done"}
          class="mb-1.5 block text-xs font-semibold text-base-content/70"
        >
          Done when
        </label>
        <input
          id={"step-#{@step.uid}-done"}
          name={"steps[#{@step.uid}][done_when]"}
          type="text"
          value={@step.done_when}
          phx-debounce="250"
          placeholder="How the lead can tell this step is finished…"
          class="input input-sm w-full"
        />
      </div>

      <%!-- Options --%>
      <div class="flex flex-col gap-2.5 rounded-lg bg-base-100 p-3 text-sm">
        <div class="flex flex-wrap items-center gap-2">
          <input
            type="checkbox"
            id={"step-#{@step.uid}-send-back"}
            class="toggle toggle-sm toggle-secondary"
            checked={!is_nil(@step.on_reject)}
            disabled={@targets == [] && is_nil(@step.on_reject)}
            title={@targets == [] && is_nil(@step.on_reject) && "Add a step before this one first"}
            phx-click="toggle_flag"
            phx-value-uid={@step.uid}
            phx-value-flag="send_back"
          />
          <%= if @targets == [] && is_nil(@step.on_reject) do %>
            <label
              for={"step-#{@step.uid}-send-back"}
              class="text-base-content/45"
              title="Add a step before this one first"
            >
              Send it back to an earlier step
            </label>
          <% else %>
            <label for={"step-#{@step.uid}-send-back"}>
              If changes are requested, send it back to
            </label>
            <select
              id={"step-#{@step.uid}-on-reject"}
              name={"steps[#{@step.uid}][on_reject]"}
              class="select select-sm w-auto"
              disabled={is_nil(@step.on_reject)}
              aria-label="Send it back to"
            >
              <option
                :for={{t, n} <- Enum.with_index(@targets, 1)}
                value={t.id}
                selected={t.id == @step.on_reject}
              >
                {n} · {PlaybookBuilder.title(t)}
              </option>
              <option
                :if={@step.on_reject && !Enum.any?(@targets, &(&1.id == @step.on_reject))}
                value={@step.on_reject}
                selected
              >
                {(@target && PlaybookBuilder.title(@target)) || @step.on_reject} (after this step)
              </option>
            </select>
          <% end %>
        </div>
        <label class="flex cursor-pointer items-center gap-2">
          <input
            type="checkbox"
            id={"step-#{@step.uid}-approval"}
            class="toggle toggle-sm toggle-warning"
            checked={@step.approval}
            phx-click="toggle_flag"
            phx-value-uid={@step.uid}
            phx-value-flag="approval"
          /> Wait for my approval before moving on
        </label>
        <label class="flex cursor-pointer items-center gap-2">
          <input
            type="checkbox"
            id={"step-#{@step.uid}-optional"}
            class="toggle toggle-sm"
            checked={@step.optional}
            phx-click="toggle_flag"
            phx-value-uid={@step.uid}
            phx-value-flag="optional"
          /> The lead may skip this step
        </label>
      </div>

      <%!-- Footer --%>
      <div class="flex flex-wrap items-center gap-2">
        <p class="min-w-0 flex-1 text-xs text-base-content/45">
          Step key <span class="font-mono">{@step.id}</span> · agents use it to send work back here
        </p>
        <div class="relative">
          <.row_menu id={"step-menu-#{@step.uid}"} label={"More for step #{@n}"}>
            <.row_menu_item
              id={"move-up-#{@step.uid}"}
              icon="hero-arrow-up-mini"
              phx-click="move_step"
              phx-value-uid={@step.uid}
              phx-value-delta="-1"
            >
              Move up
            </.row_menu_item>
            <.row_menu_item
              id={"move-down-#{@step.uid}"}
              icon="hero-arrow-down-mini"
              phx-click="move_step"
              phx-value-uid={@step.uid}
              phx-value-delta="1"
            >
              Move down
            </.row_menu_item>
            <li role="none">
              <button
                type="button"
                role="menuitem"
                id={"change-key-#{@step.uid}"}
                phx-click="popover"
                phx-value-id={"key:" <> @step.uid}
              >
                <.icon name="hero-key-mini" class="size-4" /> Change key…
              </button>
            </li>
          </.row_menu>
          <div
            :if={@popover == "key:" <> @step.uid}
            id="key-popover"
            role="dialog"
            aria-label="Change step key"
            class="pop absolute bottom-full right-0 z-30 mb-1 w-72 rounded-box border border-base-300 bg-base-200 p-3"
            phx-click-away="close_popover"
            phx-window-keydown="close_popover"
            phx-key="Escape"
          >
            <label for={"key-input-#{@step.uid}"} class="text-xs font-medium text-base-content/60">Step key</label>
            <div class="mt-1 flex gap-2">
              <input
                id={"key-input-#{@step.uid}"}
                type="text"
                value={@step.id}
                class="input input-sm flex-1 font-mono"
                phx-keydown={JS.push("change_key", value: %{uid: @step.uid})}
                phx-key="Enter"
              />
            </div>
            <p :if={@key_error} class="mt-1 text-xs text-error">{@key_error}</p>
            <p class="mt-2 text-[11px] text-base-content/55">
              Send-backs to this step follow the new key. Press Enter to apply.
            </p>
          </div>
        </div>
        <button
          type="button"
          id={"duplicate-step-#{@step.uid}"}
          class="btn btn-ghost btn-xs font-normal"
          phx-click="duplicate_step"
          phx-value-uid={@step.uid}
          disabled={@total >= PlaybookBuilder.max_steps()}
        >
          Duplicate
        </button>
        <button
          type="button"
          id={"delete-step-#{@step.uid}"}
          class="btn btn-ghost btn-xs font-normal text-error"
          phx-click="delete_step"
          phx-value-uid={@step.uid}
        >
          Delete step
        </button>
      </div>
    </div>
    """
  end

  defp owner_agent_label("coordinator", %{coordinator: nil}), do: "the run's lead"
  defp owner_agent_label("coordinator", %{coordinator: name}), do: "@" <> name

  defp owner_agent_label(role, draft) do
    case Enum.find(draft.roles, &(&1.key == role)) do
      %{agent: name} when is_binary(name) -> "@" <> name
      _ -> if draft.team, do: "from @#{draft.team}", else: "no agent yet"
    end
  end

  attr :options, :map, required: true
  attr :draft, :map, required: true
  attr :by_name, :map, required: true

  defp owner_picker(assigns) do
    ~H"""
    <div
      id="owner-picker"
      role="dialog"
      aria-label="Who does it"
      class="pop absolute left-0 top-full z-30 mt-1 w-80 max-w-[90vw] rounded-box border border-base-300 bg-base-200 p-1.5"
      phx-click-away="close_popover"
      phx-window-keydown="close_popover"
      phx-key="Escape"
    >
      <input
        id="owner-query"
        name="owner_query"
        type="text"
        placeholder="Find a role or agent…"
        phx-debounce="100"
        class="input input-sm mb-1 w-full"
        phx-mounted={JS.focus()}
      />
      <ul
        role="listbox"
        aria-multiselectable="true"
        aria-label="Who does it"
        class="max-h-80 overflow-y-auto"
        data-popover-list
      >
        <li
          :if={@options.roles != []}
          class="px-2.5 pb-1 pt-2 text-[11px] font-semibold uppercase tracking-wider text-base-content/45"
        >
          Roles in this playbook
        </li>
        <li
          :for={role <- @options.roles}
          role="option"
          aria-selected={to_string(role.key in @options.step.owner)}
        >
          <button
            type="button"
            id={"owner-option-#{role.key}"}
            class={popover_item()}
            phx-click="toggle_owner"
            phx-value-uid={@options.step.uid}
            phx-value-role={role.key}
          >
            <.avatar agent={
              role.agent && (Map.get(@by_name, role.agent) || %{name: role.agent, color: nil})
            } />
            <span class="flex-1"><span class="font-medium">{PlaybookBuilder.humanize(role.key)}</span>
            <span :if={role.agent} class="text-base-content/50">@{role.agent}</span></span>
            <.icon
              :if={role.key in @options.step.owner}
              name="hero-check-mini"
              class="size-4 text-primary"
            />
          </button>
        </li>
        <li
          :if={@options.lead}
          role="option"
          aria-selected={to_string("coordinator" in @options.step.owner)}
        >
          <button
            type="button"
            id="owner-option-lead"
            class={popover_item()}
            phx-click="toggle_owner"
            phx-value-uid={@options.step.uid}
            phx-value-role="coordinator"
          >
            <.owner_avatar owner="coordinator" draft={@draft} by_name={@by_name} />
            <span class="flex-1"><span class="font-medium">Lead</span>
            <span class="text-base-content/50">the run's lead</span></span>
            <.icon
              :if={"coordinator" in @options.step.owner}
              name="hero-check-mini"
              class="size-4 text-primary"
            />
          </button>
        </li>
        <li :if={@options.agents != []} role="separator" class="my-1 h-px bg-base-300"></li>
        <li
          :if={@options.agents != []}
          class="px-2.5 pb-1 pt-1 text-[11px] font-semibold uppercase tracking-wider text-base-content/45"
        >
          Other agents · adds a role
        </li>
        <li :for={agent <- @options.agents} role="option" aria-selected="false">
          <button
            type="button"
            id={"owner-agent-#{agent.name}"}
            class={popover_item()}
            phx-click="owner_agent"
            phx-value-uid={@options.step.uid}
            phx-value-agent={agent.name}
          >
            <.avatar agent={agent} />
            <span class="flex-1 font-medium">@{agent.name}</span>
            <span class="text-xs text-base-content/45">as "{PlaybookBuilder.humanize(agent.name)}"</span>
          </button>
        </li>
        <li role="separator" class="my-1 h-px bg-base-300"></li>
        <li>
          <button
            type="button"
            id="owner-new-role"
            class={popover_item()}
            phx-click="owner_new_role"
            phx-value-uid={@options.step.uid}
          >
            + New role with no agent yet…
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :index, :integer, required: true
  attr :class, :string, default: "top-full mt-1"

  defp add_menu(assigns) do
    ~H"""
    <div
      id="add-step-menu"
      role="dialog"
      aria-label={"Add step #{@index + 1}"}
      class={[
        "pop absolute left-1/2 z-30 w-[400px] max-w-[90vw] -translate-x-1/2 rounded-box border border-base-300 bg-base-200 p-1.5",
        @class
      ]}
      phx-click-away="close_popover"
      phx-window-keydown="close_popover"
      phx-key="Escape"
    >
      <p class="px-2.5 pb-1 pt-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/45">
        Add step {@index + 1}
      </p>
      <ul data-popover-list>
        <li :for={{preset, icon, tile, title, hint} <- presets(@index)}>
          <button
            type="button"
            id={"preset-#{preset}"}
            class={[popover_item(), "items-start"]}
            phx-click="add_step"
            phx-value-index={@index}
            phx-value-preset={preset}
          >
            <span class={["flex size-8 shrink-0 items-center justify-center rounded-lg text-sm", tile]}>{icon}</span>
            <span class="min-w-0 flex-1">
              <span class="block font-medium">{title}</span>
              <span class="block text-xs text-base-content/55">{hint}</span>
            </span>
          </button>
        </li>
      </ul>
      <p class="border-t border-base-300 px-2.5 pb-1 pt-2 text-[11px] text-base-content/55">
        You can change any of this after adding it.
      </p>
    </div>
    """
  end

  defp presets(index) do
    [
      {"task", "→", "bg-base-200 border border-base-300", "Task for an agent",
       "One person does it"},
      {"parallel", "⇉", "bg-base-100", "Parallel work", "Two or more people at the same time"},
      index > 0 &&
        {"review", "↩︎", "bg-secondary/10 text-secondary", "Review",
         "Can send work back to the step above"},
      {"sign_off", "✓", "bg-warning/10 text-warning", "Your sign-off",
       "The lead waits for your approval"},
      {"lead", "★", "bg-primary/10 text-primary", "Lead's step", "The lead does it"}
    ]
    |> Enum.filter(& &1)
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: nil
  attr :by_name, :map, required: true
  attr :rows, :integer, default: 4

  # Markdown in a textarea, shown rendered until clicked; the toolbar
  # (the PlaybookBuilder hook) inserts Markdown around the selection.
  # Which half shows is the browser's call (`data-editing`, set on focus and
  # kept across patches), so text typed into an empty field never makes the
  # editor swap itself for the preview mid-word. CSS: `.md-field` in app.css.
  defp md_field(assigns) do
    assigns =
      assigns
      |> assign(:blank?, String.trim(assigns.value || "") == "")

    ~H"""
    <div id={"#{@id}-field"} class="md-field" data-blank={@blank?}>
      <div
        id={"#{@id}-preview"}
        role="button"
        tabindex="0"
        aria-label="Edit"
        class="md-preview message-body min-h-12 cursor-text rounded-lg border border-transparent bg-base-100 px-3 py-2 text-sm hover:border-base-300"
        phx-click={JS.focus(to: "##{@id}")}
        phx-keydown={JS.focus(to: "##{@id}")}
        phx-key="Enter"
      >
        {markdown(@value, @by_name)}
      </div>
      <div
        id={"#{@id}-editor"}
        class="md-editor rounded-lg border border-base-300 bg-base-100 focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/40"
      >
        <div
          class="flex items-center gap-0.5 border-b border-base-300 px-1.5 py-1 text-xs text-base-content/60"
          data-md-toolbar={@id}
        >
          <button
            type="button"
            class="rounded px-1.5 py-0.5 font-bold hover:bg-base-200"
            data-md="bold"
            title="Bold"
          >B</button>
          <button
            type="button"
            class="rounded px-1.5 py-0.5 italic hover:bg-base-200"
            data-md="italic"
            title="Italic"
          >I</button>
          <button
            type="button"
            class="rounded px-1.5 py-0.5 font-mono hover:bg-base-200"
            data-md="code"
            title="Code"
          >&lt;/&gt;</button>
          <button
            type="button"
            class="rounded px-1.5 py-0.5 hover:bg-base-200"
            data-md="list"
            title="List"
          >• List</button>
          <button
            type="button"
            class="rounded px-1.5 py-0.5 hover:bg-base-200"
            data-md="mention"
            title="Mention an agent"
          >@ Agent</button>
        </div>
        <textarea
          id={@id}
          name={@name}
          rows={@rows}
          phx-debounce="300"
          placeholder={@placeholder}
          class="auto-grow block min-h-24 w-full resize-none border-0 bg-transparent px-3 py-2 text-sm leading-relaxed outline-none focus:ring-0"
        >{@value}</textarea>
      </div>
    </div>
    """
  end

  attr :owner, :string, required: true
  attr :draft, :map, required: true
  attr :by_name, :map, required: true

  defp owner_avatar(%{owner: "coordinator"} = assigns) do
    assigns = assign(assigns, :agent, lead_agent(assigns.draft, assigns.by_name))

    ~H"""
    <.avatar :if={@agent} agent={@agent} />
    <span
      :if={!@agent}
      class="flex size-5 items-center justify-center rounded-md bg-primary/15 text-[10px] text-primary"
      aria-hidden="true"
    >
      ★
    </span>
    """
  end

  defp owner_avatar(assigns) do
    assigns = assign(assigns, :agent, role_agent(assigns.draft, assigns.owner, assigns.by_name))

    ~H"""
    <.avatar agent={@agent} />
    """
  end

  attr :notes, :list, required: true

  defp notes_line(assigns) do
    ~H"""
    <p
      id="builder-notes"
      class="flex items-start gap-2 rounded-lg bg-base-200 px-3 py-2 text-xs text-base-content/65"
    >
      <.icon name="hero-information-circle-mini" class="mt-px size-4 shrink-0" />
      <span>
        {length(@notes)} {if length(@notes) == 1, do: "note", else: "notes"} in the file {if length(
                                                                                               @notes
                                                                                             ) == 1,
                                                                                             do:
                                                                                               "isn't",
                                                                                             else:
                                                                                               "aren't"} attached to a step:
        <span :for={{heading, _} <- @notes} class="font-mono">## {heading}</span>
        · kept at the end of the file. Use Edit file text to move or remove {if length(@notes) == 1,
          do: "it",
          else: "them"}.
      </span>
    </p>
    """
  end

  defp guidance_card(assigns) do
    assigns = assign(assigns, :blank?, String.trim(assigns.draft.guidance || "") == "")

    ~H"""
    <section
      id="guidance-card"
      class={[
        "rounded-box p-5 sm:p-6",
        @blank? && !@editing_guidance && "border border-dashed border-base-300",
        (!@blank? || @editing_guidance) && "border border-base-300 bg-base-200"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold">Ground rules for every step</h2>
          <p class="text-xs text-base-content/55">
            The lead reads these at the start of the run and keeps to them throughout.
            <span :if={@blank? && !@editing_guidance}>Optional.</span>
          </p>
        </div>
        <button
          :if={!@blank? && !@editing_guidance}
          type="button"
          id="edit-guidance"
          class="btn btn-ghost btn-xs font-normal"
          phx-click="edit_guidance"
        >
          Edit
        </button>
      </div>
      <%= cond do %>
        <% @editing_guidance -> %>
          <div class="mt-3">
            <.md_field
              id="guidance"
              name="guidance"
              value={@draft.guidance}
              by_name={@by_name}
              rows={6}
              placeholder="What holds for the whole run: what the channel task says, how steps are handed out, what nobody does without asking."
            />
          </div>
        <% @blank? -> %>
          <button
            type="button"
            id="add-guidance"
            class="mt-3 text-sm text-primary hover:underline"
            phx-click="edit_guidance"
          >
            + Add ground rules
          </button>
        <% true -> %>
          <div id="guidance-rendered" class="message-body mt-3 text-sm">
            {markdown(@draft.guidance, @by_name)}
          </div>
      <% end %>
    </section>
    """
  end

  attr :undo, :map, required: true

  defp undo_toast(assigns) do
    ~H"""
    <div
      id="undo-toast"
      role="status"
      class="fixed bottom-6 left-1/2 z-40 flex -translate-x-1/2 items-center gap-3 rounded-full bg-neutral px-4 py-2 text-sm text-neutral-content shadow-lg"
    >
      <span>{@undo.text}</span>
      <button
        type="button"
        id="undo-delete"
        class="font-semibold text-primary-content underline"
        phx-click="undo"
      >
        Undo
      </button>
      <button
        type="button"
        class="opacity-60 hover:opacity-100"
        phx-click="dismiss_undo"
        aria-label="Dismiss"
      >
        ×
      </button>
    </div>
    """
  end

  attr :reasons, :list, required: true
  attr :agent, :any, required: true

  defp unreadable_card(assigns) do
    ~H"""
    <section
      id="unreadable-card"
      class="rounded-box border border-error/30 bg-error/5 p-5 sm:p-6"
      role="alert"
    >
      <h2 class="text-base font-semibold">This playbook has problems the editor can't show yet</h2>
      <ul class="mt-2 flex flex-col gap-1 text-sm text-base-content/80">
        <li :for={reason <- @reasons} class="flex items-start gap-2">
          <.icon name="hero-exclamation-circle-mini" class="mt-0.5 size-4 shrink-0 text-error" />
          {PlaybookBuilder.plain_words(reason)}
        </li>
      </ul>
      <div class="mt-4 flex flex-wrap gap-2">
        <button
          :if={@agent}
          type="button"
          id="ask-fix"
          class="btn btn-primary btn-sm"
          phx-click="ask_fix"
          phx-value-agent={@agent.name}
        >
          Ask @{@agent.name} to fix it
        </button>
        <button
          type="button"
          id="edit-file-text"
          class="btn btn-ghost btn-sm"
          phx-click="text_mode"
          data-canopy-confirm="The file text is Markdown with settings between the --- lines at the top. Fix the problems listed, then save."
          data-canopy-confirm-title="Edit the file text?"
          data-canopy-confirm-label="Edit file text"
        >
          Edit file text
        </button>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true

  defp text_editor(assigns) do
    assigns =
      assign(
        assigns,
        :errors,
        if(assigns.form.source.action,
          do: Enum.map(assigns.form[:body].errors, &translate_error/1),
          else: []
        )
      )

    ~H"""
    <Layouts.panel
      id="playbook-text-panel"
      title="File text"
      description="Markdown with settings between the --- lines, then the ground rules and a ## section per step."
    >
      <.form
        for={@form}
        id="playbook-text-form"
        phx-change="text_validate"
        phx-submit="text_save"
        class="flex flex-col gap-3"
      >
        <textarea
          id="playbook-body"
          name="playbook[body]"
          rows="28"
          phx-debounce="300"
          spellcheck="false"
          class="textarea w-full font-mono text-xs leading-relaxed"
          aria-label="Playbook text"
        >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
        <ul :if={@errors != []} id="playbook-errors" class="flex flex-col gap-1">
          <li :for={msg <- @errors} class="flex items-start gap-2 text-sm text-error">
            <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
            {msg}
          </li>
        </ul>
        <div class="flex items-center gap-2">
          <.button type="submit" variant="primary" id="save-playbook-text">Save file text</.button>
          <button type="button" class="btn btn-ghost" phx-click="text_cancel">Back to the builder</button>
        </div>
      </.form>
    </Layouts.panel>
    """
  end
end
