defmodule CanopyWeb.SearchLive do
  @moduledoc """
  Search across every channel: messages, finished turns (the commands an
  agent ran, the files it changed, what it concluded) and shared files, in
  one ranked list from `Canopy.Search`.

  Everything lives in the URL (`q`, `kind`, `channel`, `agent`, `date` with
  `from`/`to`, `archived=1`, `sort=newest`; defaults are left out), so a
  search can be reloaded and shared. Typing patches the URL (replacing the
  history entry), and the last word matches as a prefix while it is typed.
  Results are a snapshot: the page does not follow the timeline; Refresh
  runs the query again.

  Each result opens the exact place: a channel message at its row in the
  feed (`?msg=`, with history around it when it is old), a thread reply in
  its thread, a turn in the activity panel, a file in a new tab.
  """

  use CanopyWeb, :live_view

  alias Canopy.{Agents, Channels, Documents, Search}
  alias Canopy.MCP.Format
  alias Canopy.Schedules.When
  alias CanopyWeb.{ChannelLive, TimelineComponents}

  @page 30
  @kinds [{nil, "All"}, {"message", "Messages"}, {"turn", "Turns"}, {"document", "Files"}]
  @dates ~w(today 7d 30d custom)
  @empty %{"message" => 0, "turn" => 0, "document" => 0}

  @impl true
  def mount(_params, _session, socket) do
    agents = Agents.list()

    {:ok,
     socket
     |> assign(:page_title, "Search")
     |> assign(:all_agents, agents)
     |> assign(:names, Map.new(agents, &{&1.id, &1.name}))
     |> assign(:user, Canopy.Users.local())
     |> assign(:kinds, @kinds)
     |> assign(:counts, @empty)
     |> assign(:total, 0)
     |> assign(:shown, 0)
     |> assign(:as_of, nil)
     |> stream_configure(:results, dom_id: &"row-#{&1.ref_id}")
     |> stream(:results, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    state = parse(params)

    {:noreply,
     socket
     |> assign(:state, state)
     |> assign(:query_form, to_form(%{"q" => state.q}, id: "search-form"))
     |> assign(:filters, filters_form(state))
     |> run(0)}
  end

  # -- URL state -----------------------------------------------------------------

  # Unknown values are dropped, never turned into atoms.
  defp parse(params) do
    channel = with id when is_binary(id) <- params["channel"], do: Channels.get(id)
    agent = params["agent"]
    date = if params["date"] in @dates, do: params["date"]
    from = date_param(params["from"])
    to = date_param(params["to"])

    %{
      q: params |> Map.get("q", "") |> to_string(),
      kind: if(params["kind"] in ~w(message turn document), do: params["kind"]),
      channel: channel && channel.id,
      channel_archived?: channel != nil and Channels.archived?(channel),
      agent: if(agent == "me" or (is_binary(agent) and Agents.get(agent)), do: agent),
      date: if(date == "custom" and is_nil(from) and is_nil(to), do: nil, else: date),
      from: if(date == "custom", do: from),
      to: if(date == "custom", do: to),
      archived: params["archived"] == "1",
      sort: if(params["sort"] == "newest", do: "newest", else: "best")
    }
  end

  defp date_param(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date_param(_value), do: nil

  @doc "The page's URL for `state`, with `changes` applied; defaults are left out."
  def search_path(state, changes \\ %{}) do
    state = Map.merge(state, changes)

    query =
      [
        q: state.q,
        kind: state.kind,
        channel: state.channel,
        agent: state.agent,
        date: state.date,
        from: state.date == "custom" && state.from && Date.to_iso8601(state.from),
        to: state.date == "custom" && state.to && Date.to_iso8601(state.to),
        archived: state.archived && "1",
        sort: state.sort == "newest" && "newest"
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false, ""] end)

    if query == [], do: ~p"/search", else: ~p"/search?#{query}"
  end

  defp filters_form(state) do
    to_form(
      %{
        "channel" => state.channel || "",
        "agent" => state.agent || "",
        "date" => state.date || "",
        "from" => state.from && Date.to_iso8601(state.from),
        "to" => state.to && Date.to_iso8601(state.to),
        "archived" => state.archived,
        "sort" => state.sort
      },
      as: :filters,
      id: "search-filters"
    )
  end

  # -- Searching -----------------------------------------------------------------

  defp run(socket, offset) do
    state = socket.assigns.state

    %{results: results, counts: counts, total: total} =
      Search.search(state.q,
        sources: state.kind && [state.kind],
        channel_ids: state.channel && [state.channel],
        agent: if(state.agent == "me", do: :user, else: state.agent),
        from: date_range(state) |> elem(0),
        to: date_range(state) |> elem(1),
        include_archived: state.archived or state.channel_archived?,
        sort: if(state.sort == "newest", do: :newest, else: :best),
        prefix_last: true,
        limit: @page,
        offset: offset
      )

    results = with_usages(results)
    shown = offset + length(results)

    socket
    |> assign(:counts, counts)
    |> assign(:total, total)
    |> assign(:shown, shown)
    |> assign(:as_of, DateTime.utc_now())
    |> stream(:results, results, reset: offset == 0)
  end

  defp date_range(%{date: nil}), do: {nil, nil}
  defp date_range(%{date: "custom", from: from, to: to}), do: {from, to}

  defp date_range(%{date: date}) do
    today = DateTime.utc_now() |> When.to_local_naive() |> NaiveDateTime.to_date()

    case date do
      "today" -> {today, today}
      "7d" -> {Date.add(today, -6), today}
      "30d" -> {Date.add(today, -29), today}
    end
  end

  # A file links to itself; "posted in" goes to where it was first shared.
  defp with_usages(results) do
    usages =
      results
      |> Enum.filter(&(&1.source == "document"))
      |> Enum.map(& &1.ref_id)
      |> Documents.first_usages()

    Enum.map(results, &Map.put(&1, :usage, Map.get(usages, &1.ref_id)))
  end

  # -- Events --------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: search_path(socket.assigns.state, %{q: q}), replace: true)}
  end

  def handle_event("submit", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: search_path(socket.assigns.state, %{q: q}))}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: search_path(socket.assigns.state, %{q: ""}), replace: true)}
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    state = socket.assigns.state
    date = if params["date"] in @dates, do: params["date"]

    changes = %{
      channel: blank_to_nil(params["channel"]),
      agent: blank_to_nil(params["agent"]),
      date: date,
      from: if(date == "custom", do: date_param(params["from"]) || state.from),
      to: if(date == "custom", do: date_param(params["to"]) || state.to),
      archived: params["archived"] == "true",
      sort: if(params["sort"] == "newest", do: "newest", else: "best")
    }

    # a custom range shows its two inputs at once, even before a day is picked
    socket =
      if date == "custom" and is_nil(changes.from) and is_nil(changes.to),
        do: assign(socket, :filters, filters_form(Map.merge(state, changes))),
        else: push_patch(socket, to: search_path(state, changes))

    {:noreply, socket}
  end

  def handle_event("more", _params, socket) do
    if socket.assigns.shown < min(socket.assigns.total, Search.max_rows()),
      do: {:noreply, run(socket, socket.assigns.shown)},
      else: {:noreply, socket}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, run(socket, 0)}

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # -- Links and labels ------------------------------------------------------------

  @doc """
  Where a result opens: a channel message at its row (`?msg=`), a thread
  reply in its thread, a turn in the activity panel, a file itself.
  """
  def result_link(%{source: "message", record: %{thread_id: root_id} = message})
      when is_binary(root_id),
      do: ChannelLive.thread_path(message.channel_id, root_id, message.id)

  def result_link(%{source: "message", record: message}),
    do: ~p"/channels/#{message.channel_id}?#{[msg: message.id]}"

  def result_link(%{source: "turn", record: event}),
    do: ChannelLive.activity_path(event.channel_id, event.id)

  def result_link(%{source: "document", record: document}), do: Documents.url_path(document)

  @doc """
  A snippet as safe HTML, on one line: Markdown stripped (unless
  `markdown?` is false), everything escaped,
  inline code as `<code>` and the match markers as `<mark>`
  (`CanopyWeb.Markdown.preview_html/2`). Bodies are raw Markdown that may hold
  HTML; only those two tags ever become markup.
  """
  def snippet(text, markdown? \\ true)

  def snippet(text, markdown?) when is_binary(text),
    do: CanopyWeb.Markdown.preview_html(text, Search.marks(), markdown: markdown?)

  def snippet(_text, _markdown?), do: ""

  # Only Markdown files lose their syntax; other text (code, logs) stays as written.
  defp markdown_file?(%{filename: name}) when is_binary(name),
    do: Path.extname(name) |> String.downcase() |> Kernel.in([".md", ".markdown"])

  defp markdown_file?(_document), do: false

  defp channel_label(%{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp channel_label(channel), do: "#" <> channel.name

  defp sender(%{agent: %{name: name}}, _user_name) when is_binary(name), do: "@" <> name
  defp sender(%{user: %{display_name: name}}, _user_name) when is_binary(name), do: name
  defp sender(_result, user_name), do: user_name

  defp full_time(at),
    do: at |> When.to_local_naive() |> Calendar.strftime("%Y-%m-%d %H:%M")

  defp channel_options(repositories, dms, state) do
    shown? = fn channel ->
      channel.status == "open" or state.archived or channel.id == state.channel
    end

    groups =
      for repository <- repositories,
          channels = Enum.filter(repository.channels, shown?),
          channels != [] do
        {repository.name,
         Enum.map(channels, fn channel ->
           suffix = if channel.status == "archived", do: " (archived)", else: ""
           {"#" <> channel.name <> suffix, channel.id}
         end)}
      end

    case Enum.filter(dms, shown?) do
      [] -> groups
      dms -> groups ++ [{"Direct messages", Enum.map(dms, &{Channels.dm_label(&1), &1.id})}]
    end
  end

  defp agent_options(agents) do
    [
      {"You", "me"}
      | Enum.map(agents, &{"@" <> &1.name <> if(&1.active, do: "", else: " (retired)"), &1.id})
    ]
  end

  defp active_filters(state) do
    Enum.count(
      [
        state.channel,
        state.agent,
        state.date,
        state.archived || nil,
        state.sort == "newest" || nil
      ],
      & &1
    )
  end

  defp count_label(counts, nil), do: counts |> Map.values() |> Enum.sum()
  defp count_label(counts, kind), do: Map.get(counts, kind, 0)

  defp searchable?(q), do: Canopy.Search.Query.searchable_length(q) >= 2

  defp channel_name(channels_and_dms, id) do
    Enum.find_value(channels_and_dms, fn channel -> channel.id == id && channel_label(channel) end)
  end

  # -- Render ----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :scope_name, scope_name(assigns))

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
      <Layouts.page title="Search" max_width="max-w-4xl">
        <div class="flex flex-col gap-3">
          <.form
            for={@query_form}
            id="search-form"
            phx-change="search"
            phx-submit="submit"
            class="relative"
          >
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-1/2 z-10 size-5 -translate-y-1/2 text-base-content/40"
            />
            <input
              type="search"
              id="search-input"
              name="q"
              value={@query_form[:q].value}
              placeholder="Search messages, turns and files"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="250"
              phx-mounted={JS.focus()}
              phx-hook="SearchNav"
              data-results="#search-results"
              aria-label="Search"
              aria-controls="search-results"
              class={[
                "input input-lg w-full pl-11 pr-11",
                "[&::-webkit-search-cancel-button]:appearance-none",
                "[&::-webkit-search-decoration]:appearance-none"
              ]}
            />
            <button
              :if={@state.q != ""}
              type="button"
              id="search-clear"
              class="btn btn-sm btn-ghost btn-circle absolute right-2 top-1/2 -translate-y-1/2"
              phx-click="clear"
              aria-label="Clear the search"
            >
              <.icon name="hero-x-mark-mini" class="size-4" />
            </button>
          </.form>

          <nav
            id="search-tabs"
            class="-mx-1 flex items-center gap-1 overflow-x-auto px-1"
            aria-label="Result kinds"
          >
            <.link
              :for={{kind, label} <- @kinds}
              patch={search_path(@state, %{kind: kind})}
              id={"search-tab-#{kind || "all"}"}
              class={[
                "btn btn-sm shrink-0 gap-1.5",
                @state.kind == kind && "btn-primary btn-soft",
                @state.kind != kind && "btn-ghost"
              ]}
              aria-current={@state.kind == kind && "page"}
            >
              {label}
              <span
                :if={searchable?(@state.q)}
                id={"search-count-#{kind || "all"}"}
                class="text-xs font-normal opacity-70"
              >
                {count_label(@counts, kind)}
              </span>
            </.link>
          </nav>

          <button
            type="button"
            id="search-filters-toggle"
            class="btn btn-sm btn-ghost self-start md:hidden"
            phx-click={JS.toggle_class("max-md:hidden", to: "#search-filters-body")}
          >
            <.icon name="hero-adjustments-horizontal-mini" class="size-4" />
            Filters{if active_filters(@state) > 0, do: " (#{active_filters(@state)})"}
          </button>

          <div id="search-filters-body" class="max-md:hidden">
            <.form
              for={@filters}
              id="search-filters"
              phx-change="filter"
              class="flex flex-wrap items-end gap-x-3 gap-y-1 rounded-xl border border-base-300 bg-base-200 px-3 pt-2"
            >
              <div class="w-full sm:w-52">
                <.input
                  field={@filters[:channel]}
                  type="select"
                  label="Channel"
                  prompt="Any channel"
                  options={channel_options(@repositories, @dms, @state)}
                  class="select select-sm w-full"
                />
              </div>
              <div class="w-full sm:w-44">
                <.input
                  field={@filters[:agent]}
                  type="select"
                  label="From"
                  prompt="Anyone"
                  options={agent_options(@all_agents)}
                  class="select select-sm w-full"
                />
              </div>
              <div class="w-full sm:w-40">
                <.input
                  field={@filters[:date]}
                  type="select"
                  label="Date"
                  prompt="Any time"
                  options={[
                    {"Today", "today"},
                    {"Past 7 days", "7d"},
                    {"Past 30 days", "30d"},
                    {"Custom…", "custom"}
                  ]}
                  class="select select-sm w-full"
                />
              </div>
              <%= if @filters[:date].value == "custom" do %>
                <div class="w-36">
                  <.input
                    field={@filters[:from]}
                    type="date"
                    label="From day"
                    class="input input-sm w-full"
                  />
                </div>
                <div class="w-36">
                  <.input
                    field={@filters[:to]}
                    type="date"
                    label="To day"
                    class="input input-sm w-full"
                  />
                </div>
              <% end %>
              <div class="w-full sm:w-36">
                <.input
                  field={@filters[:sort]}
                  type="select"
                  label="Sort"
                  options={[{"Best match", "best"}, {"Newest", "newest"}]}
                  class="select select-sm w-full"
                />
              </div>
              <div class="pb-1.5">
                <.input field={@filters[:archived]} type="checkbox" label="Archived" />
              </div>
            </.form>
          </div>

          <%= cond do %>
            <% not searchable?(@state.q) -> %>
              <Layouts.empty_state
                id="search-empty"
                icon="hero-magnifying-glass"
                title="Search messages, turn summaries and files"
              >
                <p>
                  <code>"exact phrase"</code>
                  · <code>prefix*</code>
                  · code and paths like <code>lib/billing/worker.py</code>
                  work as typed
                </p>
                <p class="mt-1">
                  Words match whole: <code>worker</code>
                  doesn't find <code>PaymentWorker</code>; <code>Payment*</code>
                  does.
                </p>
              </Layouts.empty_state>
            <% @total == 0 -> %>
              <Layouts.empty_state
                id="search-none"
                icon="hero-magnifying-glass"
                title={"Nothing matches “#{@state.q}”#{@scope_name}."}
              >
                <div class="mt-1 flex flex-wrap justify-center gap-2">
                  <.link
                    :if={@state.channel}
                    patch={search_path(@state, %{channel: nil})}
                    id="search-everywhere"
                    class="btn btn-xs"
                  >
                    Search all channels
                  </.link>
                  <.link
                    :if={!@state.archived}
                    patch={search_path(@state, %{archived: true})}
                    id="search-include-archived"
                    class="btn btn-xs"
                  >
                    Include archived
                  </.link>
                </div>
              </Layouts.empty_state>
            <% true -> %>
          <% end %>

          <ul
            id="search-results"
            phx-update="stream"
            class={[
              "flex flex-col divide-y divide-base-300 overflow-hidden rounded-xl border border-base-300 bg-base-200",
              (not searchable?(@state.q) or @total == 0) && "hidden"
            ]}
            role="listbox"
            aria-label="Results"
          >
            <li :for={{id, result} <- @streams.results} id={id} class="group relative">
              <.result result={result} names={@names} user_name={@user.display_name} />
            </li>
          </ul>

          <div
            :if={searchable?(@state.q) and @total > 0}
            class="flex flex-col items-center gap-2 text-xs text-base-content/60"
          >
            <button
              :if={@shown < min(@total, Search.max_rows())}
              type="button"
              id="search-more"
              class="btn btn-sm"
              phx-click="more"
            >
              Show more
            </button>
            <p id="search-shown">
              {@shown} of {@total}
              <span :if={@shown >= Search.max_rows() and @total > @shown}>
                · Refine the search to see older results
              </span>
            </p>
            <p :if={@as_of} id="search-as-of">
              as of {TimelineComponents.short_time(@as_of)} ·
              <button type="button" id="search-refresh" class="link" phx-click="refresh">
                Refresh
              </button>
            </p>
          </div>
        </div>
      </Layouts.page>
    </Layouts.app>
    """
  end

  defp scope_name(%{state: %{channel: nil}}), do: ""

  defp scope_name(%{state: %{channel: id}, repositories: repositories, dms: dms}) do
    case channel_name(Enum.flat_map(repositories, & &1.channels) ++ dms, id) do
      nil -> ""
      name -> " in " <> name
    end
  end

  attr :result, :map, required: true
  attr :names, :map, required: true
  attr :user_name, :string, required: true

  defp result(%{result: %{source: "document"}} = assigns) do
    ~H"""
    <a
      href={result_link(@result)}
      target="_blank"
      rel="noopener"
      id={"result-#{@result.ref_id}"}
      role="option"
      class="search-result flex flex-col gap-1 px-4 py-3 transition hover:bg-base-300/50 aria-selected:bg-primary/10"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 pr-28 text-sm">
        <.icon name="hero-document-text-mini" class="size-4 shrink-0 text-base-content/50" />
        <span class="min-w-0 truncate font-semibold">{@result.record.filename}</span>
        <span class="text-xs text-base-content/60">
          {@result.record.kind} · {Documents.size_label(@result.record.byte_size)} · {sender(
            @result,
            @user_name
          )}
        </span>
        <span :if={@result.channel} class="text-xs text-base-content/60">
          · {channel_label(@result.channel)}
        </span>
        <.ago at={@result.inserted_at} />
      </div>
      <p class="line-clamp-2 text-sm text-base-content/75 [&_mark]:rounded-sm [&_mark]:bg-warning/30 [&_mark]:px-0.5 [&_mark]:text-base-content [&_code]:rounded [&_code]:bg-base-300/60 [&_code]:px-1 [&_code]:font-mono [&_code]:text-[0.9em]">
        {snippet(@result.snippet, markdown_file?(@result.record))}
      </p>
    </a>
    <.link
      :if={@result.usage}
      navigate={~p"/channels/#{@result.usage.channel_id}?#{[msg: @result.usage.message_id]}"}
      id={"result-#{@result.ref_id}-posted"}
      class="btn btn-xs btn-ghost absolute right-3 top-2.5"
    >
      posted in chat <.icon name="hero-chevron-right-mini" class="size-3.5" />
    </.link>
    """
  end

  defp result(%{result: %{source: "turn"}} = assigns) do
    ~H"""
    <.link
      navigate={result_link(@result)}
      id={"result-#{@result.ref_id}"}
      role="option"
      class="search-result flex flex-col gap-1 px-4 py-3 transition hover:bg-base-300/50 aria-selected:bg-primary/10"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 text-sm">
        <.icon name="hero-cog-6-tooth-mini" class="size-4 shrink-0 text-base-content/50" />
        <span :if={@result.channel} class="font-semibold">{channel_label(@result.channel)}</span>
        <span class="min-w-0 truncate text-base-content/70">
          {TimelineComponents.event_text(@result.record, @names, @user_name)}
        </span>
        <span :if={@result.thread_id} class="badge badge-xs badge-ghost">thread</span>
        <.ago at={@result.inserted_at} />
      </div>
      <p class="line-clamp-2 font-mono text-xs text-base-content/75 [&_mark]:rounded-sm [&_mark]:bg-warning/30 [&_mark]:px-0.5 [&_mark]:text-base-content [&_code]:rounded [&_code]:bg-base-300/60 [&_code]:px-1 [&_code]:font-mono [&_code]:text-[0.9em]">
        {snippet(@result.snippet, false)}
      </p>
    </.link>
    """
  end

  defp result(assigns) do
    ~H"""
    <.link
      navigate={result_link(@result)}
      id={"result-#{@result.ref_id}"}
      role="option"
      class="search-result flex flex-col gap-1 px-4 py-3 transition hover:bg-base-300/50 aria-selected:bg-primary/10"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 text-sm">
        <.icon
          name="hero-chat-bubble-left-ellipsis-mini"
          class="size-4 shrink-0 text-base-content/50"
        />
        <span :if={@result.channel} class="font-semibold">{channel_label(@result.channel)}</span>
        <span class="text-base-content/70">{sender(@result, @user_name)}</span>
        <span :if={@result.thread_id} class="badge badge-xs badge-ghost">in a thread</span>
        <.ago at={@result.inserted_at} />
      </div>
      <p class="line-clamp-2 text-sm text-base-content/75 [&_mark]:rounded-sm [&_mark]:bg-warning/30 [&_mark]:px-0.5 [&_mark]:text-base-content [&_code]:rounded [&_code]:bg-base-300/60 [&_code]:px-1 [&_code]:font-mono [&_code]:text-[0.9em]">
        {snippet(@result.snippet)}
      </p>
    </.link>
    """
  end

  attr :at, :any, required: true

  defp ago(assigns) do
    ~H"""
    <time class="ml-auto shrink-0 text-xs text-base-content/50" title={full_time(@at)}>
      {Format.relative_time(@at)}
    </time>
    """
  end
end
