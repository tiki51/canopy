defmodule CanopyWeb.AgentImportLive do
  @moduledoc """
  `/agents/import`: drop a template file (an agent `.md`, a Claude Code
  subagent file, a playbook, or a bundle `.zip`) or paste one, check the
  preview, and import it. The preview (`Canopy.Templates.Import`) shows each
  item's status, its permission line, what was changed to fit this machine,
  and a choice for a taken name: rename, replace, or skip. Nothing is written
  until Import, and then all of it or nothing.

  The gallery sends its Add and Compare here with `?gallery=<agent>` or
  `?bundle=<bundle>` (`&replace=1` for Compare), and Import goes back there.
  """

  use CanopyWeb, :live_view

  alias Canopy.Templates.{Import, Machine}
  alias Canopy.Templates.Import.{Item, Plan}
  alias CanopyWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import agents")
     |> assign(:plan, nil)
     |> assign(:machine, nil)
     |> assign(:return_to, ~p"/agents")
     |> assign(:paste, to_form(%{"text" => ""}, as: :paste))
     |> allow_upload(:template,
       accept: ~w(.md .markdown .zip),
       max_entries: 1,
       max_file_size: 2_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    source =
      case params do
        %{"gallery" => name} when is_binary(name) -> {:gallery, name}
        %{"bundle" => name} when is_binary(name) -> {:gallery_bundle, name}
        _ -> nil
      end

    socket =
      if source && connected?(socket) do
        socket
        |> assign(:return_to, ~p"/agents/gallery")
        |> plan([source])
        |> maybe_replace(params["replace"] == "1")
      else
        socket
      end

    {:noreply, socket}
  end

  # Compare: the gallery entry, set to replace the agent of the same name.
  defp maybe_replace(%{assigns: %{plan: %Plan{items: [item]} = plan}} = socket, true) do
    if :replace in Item.actions(item),
      do: assign(socket, :plan, Import.choose(plan, %{item.id => %{"action" => "replace"}})),
      else: socket
  end

  defp maybe_replace(socket, _), do: socket

  defp handle_progress(:template, entry, socket) do
    if entry.done? do
      [source] =
        consume_uploaded_entries(socket, :template, fn %{path: path}, entry ->
          {:ok, {:file, entry.client_name, File.read!(path)}}
        end)

      {:noreply, plan(socket, [source])}
    else
      {:noreply, socket}
    end
  end

  # -- Events -------------------------------------------------------------------

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("paste", %{"paste" => %{"text" => text}}, socket) do
    {:noreply,
     socket |> assign(:paste, to_form(%{"text" => text}, as: :paste)) |> plan([{:text, text}])}
  end

  def handle_event(
        "choose",
        %{"choices" => choices},
        %{assigns: %{plan: %Plan{} = plan}} = socket
      )
      when is_map(choices) do
    {:noreply, assign(socket, :plan, Import.choose(plan, choices))}
  end

  def handle_event("choose", _params, socket), do: {:noreply, socket}

  def handle_event("start_over", _params, socket) do
    {:noreply,
     socket
     |> assign(:plan, nil)
     |> assign(:paste, to_form(%{"text" => ""}, as: :paste))}
  end

  def handle_event("apply", params, %{assigns: %{plan: %Plan{} = plan}} = socket) do
    plan = Import.choose(plan, Map.get(params, "choices", %{}))

    case Import.apply(plan) do
      {:ok, summary} ->
        {:noreply,
         socket
         |> Nav.refresh_nav()
         |> put_flash(:info, Import.summary_text(summary))
         |> push_navigate(to: socket.assigns.return_to)}

      {:error, :stale} ->
        {:noreply,
         socket
         |> replan(plan)
         |> put_flash(:error, "Something changed since the preview; check it again, then import.")}

      {:error, :invalid} ->
        {:noreply,
         socket
         |> assign(:plan, plan)
         |> put_flash(:error, "Fix or skip the items marked invalid first.")}

      {:error, {label, lines}} ->
        {:noreply,
         socket
         |> assign(:plan, plan)
         |> put_flash(:error, "Could not import #{label}: #{Enum.join(lines, "; ")}")}
    end
  end

  def handle_event("apply", _params, socket), do: {:noreply, socket}

  # -- Planning -------------------------------------------------------------------

  defp plan(socket, sources) do
    {machine, socket} = machine(socket)
    assign(socket, :plan, Import.plan(sources, machine: machine))
  end

  # The same sources again, against a fresh look at this machine, keeping the
  # user's picks (item ids follow the file order, so they match).
  defp replan(socket, %Plan{sources: sources, items: items}) do
    socket = assign(socket, :machine, nil)
    {machine, socket} = machine(socket)
    picks = Map.new(items, &{&1.id, &1.picked})
    fresh = sources |> Import.plan(machine: machine) |> Import.choose(picks)
    assign(socket, :plan, fresh)
  end

  defp machine(%{assigns: %{machine: %Machine{} = machine}} = socket), do: {machine, socket}

  defp machine(socket) do
    machine = Machine.probe()
    {machine, assign(socket, :machine, machine)}
  end

  # -- Render -------------------------------------------------------------------

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
    >
      <Layouts.page
        title="Import agents"
        subtitle="Agents, teams and playbooks from a template file or bundle"
      >
        <:actions>
          <.link navigate={~p"/agents/gallery"} id="import-gallery" class="btn btn-ghost btn-sm">
            <.icon name="hero-sparkles" class="size-4" /> Gallery
          </.link>
          <.link navigate={@return_to} id="import-cancel" class="btn btn-ghost btn-sm">
            Cancel
          </.link>
        </:actions>

        <.source_panel :if={is_nil(@plan)} uploads={@uploads} paste={@paste} />
        <.preview :if={@plan} plan={@plan} />
      </Layouts.page>
    </Layouts.app>
    """
  end

  attr :uploads, :map, required: true
  attr :paste, :map, required: true

  defp source_panel(assigns) do
    ~H"""
    <Layouts.panel
      id="import-source"
      title="Choose a file"
      description="An agent exported from Canopy (.md), a Claude Code subagent file, a playbook, or a bundle (.zip). Nothing is imported until you check the preview."
    >
      <form id="import-upload-form" phx-change="validate_upload" phx-submit="validate_upload">
        <label
          for={@uploads.template.ref}
          id="import-drop"
          phx-drop-target={@uploads.template.ref}
          class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-base-300 px-6 py-10 text-center transition hover:border-primary/50 hover:bg-base-200/50"
        >
          <.icon name="hero-arrow-up-tray" class="size-6 text-base-content/50" />
          <span class="text-sm font-medium">Drop a file here, or click to choose one</span>
          <span class="text-xs text-base-content/60">.md, .markdown or .zip, up to 2 MB</span>
          <.live_file_input upload={@uploads.template} class="sr-only" />
        </label>
        <div :for={entry <- @uploads.template.entries} class="mt-2 text-xs text-base-content/70">
          {entry.client_name} · {entry.progress}%
          <p :for={err <- upload_errors(@uploads.template, entry)} class="text-error">
            {upload_error(err)}
          </p>
        </div>
        <p :for={err <- upload_errors(@uploads.template)} class="mt-2 text-xs text-error">
          {upload_error(err)}
        </p>
      </form>

      <details id="import-paste" class="mt-4 group">
        <summary class="cursor-pointer text-sm text-base-content/70 hover:text-base-content">
          Paste instead
        </summary>
        <.form for={@paste} id="import-paste-form" phx-submit="paste" class="mt-2 flex flex-col gap-2">
          <textarea
            id="import-paste-text"
            name={@paste[:text].name}
            rows="10"
            class="textarea textarea-bordered w-full font-mono text-xs"
            placeholder="---&#10;canopy_template: 1&#10;kind: agent&#10;name: …&#10;---&#10;&#10;The prompt…"
          >{@paste[:text].value}</textarea>
          <div>
            <.button type="submit" id="import-paste-submit">Preview</.button>
          </div>
        </.form>
      </details>
    </Layouts.panel>
    """
  end

  defp upload_error(:too_large), do: "That file is over 2 MB."
  defp upload_error(:not_accepted), do: "Choose a .md, .markdown or .zip file."
  defp upload_error(:too_many_files), do: "One file at a time."
  defp upload_error(other), do: "Could not upload: #{other}"

  attr :plan, :map, required: true

  defp preview(assigns) do
    assigns = assign(assigns, :writing, length(Plan.writing(assigns.plan)))

    ~H"""
    <Layouts.panel id="import-preview" title="Preview">
      <:subtitle>
        <span :if={@plan.manifest} id="import-manifest">
          Bundle
          <span class="font-mono">{@plan.manifest["name"]}</span><span :if={
            @plan.manifest["description"]
          }> — {@plan.manifest["description"]}</span>.
        </span>
        Check each item, then import. Renamed names are rewritten where a team or playbook names
        them; @mentions in prompts are not.
      </:subtitle>
      <:actions>
        <button
          type="button"
          id="import-start-over"
          class="btn btn-ghost btn-xs"
          phx-click="start_over"
        >
          Choose another file
        </button>
      </:actions>

      <ul :if={@plan.errors != []} id="import-errors" class="mb-3 flex flex-col gap-1">
        <li :for={error <- @plan.errors} class="flex gap-1.5 text-sm text-error">
          <.icon name="hero-x-circle-mini" class="mt-0.5 size-4 shrink-0" /> {error}
        </li>
      </ul>
      <ul :if={@plan.notices != []} id="import-notices" class="mb-3 flex flex-col gap-1">
        <li :for={notice <- @plan.notices} class="flex gap-1.5 text-xs text-warning">
          <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 size-3.5 shrink-0" />
          {notice}
        </li>
      </ul>

      <form :if={@plan.items != []} id="import-choices" phx-change="choose" phx-submit="apply">
        <ul id="import-items" class="divide-y divide-base-300">
          <.item_row :for={item <- @plan.items} item={item} />
        </ul>

        <div class="mt-4 flex items-center gap-3 border-t border-base-300 pt-4">
          <.button
            type="submit"
            variant="primary"
            id="import-apply"
            disabled={not Plan.ready?(@plan)}
            phx-disable-with="Importing…"
          >
            Import {@writing}
          </.button>
          <span
            :if={Enum.any?(@plan.items, &(Item.writes?(&1) and &1.errors != []))}
            class="text-xs text-error"
          >
            Fix or skip the items with errors to import.
          </span>
        </div>
      </form>
    </Layouts.panel>
    """
  end

  attr :item, :map, required: true

  defp item_row(assigns) do
    ~H"""
    <li
      id={"import-#{@item.id}"}
      data-status={@item.status}
      data-action={@item.choice.action}
      class="flex flex-col gap-2 py-3"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.icon name={kind_icon(@item.kind)} class="size-4 text-base-content/50" />
        <span class="font-mono text-sm font-semibold">{original_label(@item)}</span>
        <span class={["badge badge-sm badge-soft", status_class(@item.status)]}>
          {status_text(@item)}
        </span>
        <span class="ml-auto truncate font-mono text-[11px] text-base-content/50">{@item.path}</span>
      </div>

      <p :if={@item.kind == :agent and @item.template} class="text-xs text-base-content/70">
        {@item.template.display_name || @item.template.name}<span :if={@item.template.role}> — {@item.template.role}</span>
      </p>

      <p
        :if={@item.permission}
        id={"import-#{@item.id}-permission"}
        class={[
          "flex items-center gap-1.5 font-mono text-xs",
          if(@item.permission.risky, do: "text-warning", else: "text-base-content/70")
        ]}
      >
        <.icon name="hero-shield-check-mini" class="size-3.5 shrink-0" /> {@item.permission.text}
      </p>

      <p :if={@item.kind == :team and @item.members != []} class="text-xs text-base-content/70">
        Lead @{@item.template.lead} · members
        <span
          :for={member <- @item.members}
          class={["font-mono", is_nil(member.resolved) && "text-error"]}
        >
          @{member_name(member)}{if member.role, do: " (#{member.role})"}
        </span>
      </p>

      <ul :if={@item.errors != []} id={"import-#{@item.id}-errors"} class="flex flex-col gap-0.5">
        <li :for={error <- @item.errors} class="flex gap-1.5 text-xs text-error">
          <.icon name="hero-x-circle-mini" class="mt-0.5 size-3.5 shrink-0" /> {error}
        </li>
      </ul>
      <ul :if={@item.notices != []} id={"import-#{@item.id}-notices"} class="flex flex-col gap-0.5">
        <li :for={notice <- @item.notices} class="flex gap-1.5 text-xs text-warning">
          <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 size-3.5 shrink-0" /> {notice}
        </li>
      </ul>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
        <%!-- The new name sits right after "Import as", and only takes
             input while that is picked. --%>
        <div :for={action <- Item.actions(@item)} class="flex items-center gap-1.5">
          <label class="flex cursor-pointer items-center gap-1.5">
            <input
              type="radio"
              id={"import-#{@item.id}-#{action}"}
              name={"choices[#{@item.id}][action]"}
              value={action}
              checked={@item.choice.action == action}
              class="radio radio-xs"
            />
            {action_text(@item, action)}
          </label>
          <input
            :if={action == :rename}
            type="text"
            id={"import-#{@item.id}-name"}
            name={"choices[#{@item.id}][name]"}
            value={@item.choice.name || @item.picked[:name]}
            placeholder="new name"
            disabled={@item.choice.action != :rename}
            phx-debounce="300"
            aria-label="New name"
            class="input input-bordered input-xs w-48 font-mono focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary disabled:opacity-50"
          />
        </div>

        <select
          :if={@item.kind == :agent and @item.status != :invalid and Item.writes?(@item)}
          id={"import-#{@item.id}-engine"}
          name={"choices[#{@item.id}][engine]"}
          aria-label="Engine"
          class="select select-bordered select-xs w-auto"
        >
          <option value="default" selected={is_nil(@item.engine)}>
            Default ({Canopy.Engine.label(Canopy.Settings.default_engine())})
          </option>
          <option
            :for={engine <- Canopy.Engine.names()}
            value={engine}
            selected={@item.engine == engine}
          >
            {Canopy.Engine.label(engine)}
          </option>
        </select>

        <select
          :if={@item.memory && Item.writes?(@item)}
          id={"import-#{@item.id}-memory"}
          name={"choices[#{@item.id}][memory]"}
          aria-label="Memory"
          class="select select-bordered select-xs w-auto"
        >
          <option
            :for={{value, label} <- memory_options(@item)}
            value={value}
            selected={@item.choice.memory == value}
          >
            {label}
          </option>
        </select>
      </div>

      <details :if={@item.diff != []} id={"import-#{@item.id}-changes"} class="text-xs">
        <summary class="cursor-pointer text-base-content/70 hover:text-base-content">
          Changes from @{@item.name} here ({length(@item.diff)})
        </summary>
        <table class="mt-2 w-full table-fixed text-left">
          <tbody>
            <tr
              :for={{field, old, new} <- @item.diff}
              :if={field != :system_prompt}
              class="border-t border-base-300 align-top"
            >
              <th class="w-32 py-1 pr-2 font-medium text-base-content/60">{field}</th>
              <td class="py-1 pr-2 font-mono text-error/80 line-through">{shown(old)}</td>
              <td class="py-1 font-mono">{shown(new)}</td>
            </tr>
          </tbody>
        </table>
        <pre
          :if={@item.prompt_diff}
          id={"import-#{@item.id}-prompt-diff"}
          class="mt-2 max-h-72 overflow-auto rounded-lg bg-base-200 p-2 font-mono text-[11px] leading-relaxed"
        ><%= for {op, lines} <- @item.prompt_diff, line <- lines do %><span class={diff_class(op)}>{diff_mark(op)} {line}
    </span><% end %></pre>
      </details>
    </li>
    """
  end

  defp kind_icon(:team), do: "hero-user-group-mini"
  defp kind_icon(:playbook), do: "hero-book-open-mini"
  defp kind_icon(_), do: "hero-cpu-chip-mini"

  defp original_label(%Item{kind: :playbook, name: name}), do: "playbook #{name}"
  defp original_label(%Item{kind: :team, name: name}), do: "@#{name} (team)"
  defp original_label(%Item{name: name}), do: "@#{name}"

  defp status_class(:new), do: "badge-success"
  defp status_class(:conflict), do: "badge-warning"
  defp status_class(:identical), do: "badge-ghost"
  defp status_class(:invalid), do: "badge-error"

  defp status_text(%Item{status: :new}), do: "new"
  defp status_text(%Item{status: :identical}), do: "already here"
  defp status_text(%Item{status: :invalid}), do: "invalid"
  defp status_text(%Item{status: :conflict, existing: nil}), do: "name taken"
  defp status_text(%Item{status: :conflict}), do: "differs from the one here"

  defp action_text(_item, :create), do: "Import"
  defp action_text(_item, :rename), do: "Import as"
  defp action_text(%Item{kind: :agent}, :replace), do: "Replace the one here"
  defp action_text(_item, :replace), do: "Replace"
  defp action_text(_item, :skip), do: "Skip"

  defp memory_options(%Item{choice: %{action: :replace}}) do
    [
      {:keep, "Keep its memory"},
      {:replace, "Replace its memory"},
      {:append, "Append to its memory"}
    ]
  end

  defp memory_options(_item), do: [{:import, "Import the memory"}, {:skip, "Leave memory out"}]

  defp member_name(%{resolved: {_, name}}), do: name
  defp member_name(%{name: name}), do: name

  defp shown(nil), do: "—"
  defp shown([]), do: "—"
  defp shown(list) when is_list(list), do: Enum.join(list, ", ")
  defp shown(value), do: to_string(value)

  defp diff_class(:ins), do: "block bg-success/15"
  defp diff_class(:del), do: "block bg-error/15 text-base-content/70"
  defp diff_class(:eq), do: "block text-base-content/60"

  defp diff_mark(:ins), do: "+"
  defp diff_mark(:del), do: "-"
  defp diff_mark(:eq), do: " "
end
