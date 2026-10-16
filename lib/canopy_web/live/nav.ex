defmodule CanopyWeb.Nav do
  @moduledoc """
  `on_mount` hook for every LiveView: loads what the sidebar needs and tracks the
  current path so the layout can highlight the active item.

  Assigns: `:repositories` (each with `:channels`), `:dms`, `:agents`, `:unread`,
  `:threads_unread` (followed threads with unread replies, for the rail's Threads badge) and
  `:thread_unread_summary` (`Canopy.Unread.thread_summary/1`), `:attention`
  (question and permission cards and playbook sign-offs waiting on the user, and runs
  in progress, per channel), `:palette` (teams and enabled playbooks, for the command
  palette), `:current_path`,
  `:current_channel_id` and `:current_repository_id` (nil outside a channel). Screens that create or
  change repositories, channels, or agents should call `refresh_nav/1` after
  writing so the sidebar updates without a reload.

  Every page also pushes desktop notification notes to the browser as
  `"canopy:notify"` (`CanopyWeb.Notify`): for cards, mentions, sign-offs and
  completed tasks from `"timeline:all"`, and for channels that went quiet
  (`Canopy.Runtime.subscribe_activity/0`). On connecting it pushes the cards
  still waiting from the last half hour as `"canopy:pending"`, so a page that
  was asleep or offline can catch up.

  It also hosts first-run setup on every page: `:setup` is the step the setup
  modal (`CanopyWeb.OnboardingLive`, rendered by `CanopyWeb.Layouts.app/1`)
  opens at, or nil. It is set on mount while setup has never been finished or
  skipped, or when the URL carries `?setup=<step>` (where `/welcome` sends);
  `"open_setup"` (Settings → *Run setup again*) sets it on the spot. The modal
  closes by sending `{:canopy_setup, :close, opts}`: the page navigates, live,
  to `opts[:to]` or to itself without `?setup=`, with `opts[:flash]` as an
  info flash, so what is behind it shows what was chosen.

  It also answers the command palette's server questions on every page:
  `cmdk:files` (a filename search), `cmdk:stop` (`/stop` in a channel you are
  not in) and `cmdk:notify` (the desktop notifications switch was flipped: a
  flash says so); see `CanopyWeb.CommandPalette`.

  It is the only subscriber to `Canopy.Environment`'s broadcasts. A reset that
  deleted something (`:reset_done`, or `:reset_failed` with `deleted?: true`)
  reloads every tab, whatever page it shows, onto `/settings?reset=<id>`,
  where the banner says how it went. The other environment messages (steps,
  and failures that deleted nothing) go on to `CanopyWeb.SettingsLive` only
  and stop here on every other page. A page opened on a row that a reset
  deleted in the last few minutes (a tab that missed the broadcast) lands on
  the same banner instead of a 404. While a reset runs, `cmdk:stop` is
  refused with a flash.
  """

  use CanopyWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  alias Canopy.Channels.Sections
  alias CanopyWeb.Notify

  alias Canopy.{
    Agents,
    Attention,
    Channels,
    Documents,
    Environment,
    Hold,
    Playbooks,
    Repositories,
    Runtime,
    Schedules,
    Teams,
    Threads,
    Timeline,
    Unread,
    Users
  }

  def on_mount(:default, params, _session, socket) do
    if connected?(socket) do
      Channels.subscribe()
      Timeline.subscribe_all()
      Threads.subscribe_reads()
      Schedules.subscribe()
      Hold.subscribe()
      Canopy.Playbooks.Runs.subscribe()
      Teams.subscribe()
      Playbooks.subscribe()
      Runtime.subscribe_activity()
      Environment.subscribe()
    end

    case deleted_by_reset(socket.view, params) do
      nil -> mount_nav(socket, params)
      reset_id -> {:halt, redirect(socket, to: ~p"/settings?reset=#{reset_id}")}
    end
  end

  defp mount_nav(socket, params) do
    socket =
      socket
      |> refresh_nav()
      |> attach_hook(:canopy_nav_refresh, :handle_info, &handle_info/2)
      |> attach_hook(:canopy_nav_events, :handle_event, &handle_event/3)
      |> assign_new(:current_channel_id, fn -> nil end)
      |> assign_new(:current_repository_id, fn -> nil end)
      |> assign(:setup, setup_step(params))
      |> attach_hook(:canopy_nav_path, :handle_params, &handle_params/3)
      |> push_pending()

    {:cont, socket}
  end

  # How long after a reset a page on one of its deleted rows still goes to
  # that reset's banner; later, a missing row is a plain 404 again.
  @reset_redirect_seconds 10 * 60

  # The id of a recent reset that deleted the row this page is about, or nil.
  # Only pages whose route carries a deleted row's id look; the reset is
  # checked before the row.
  defp deleted_by_reset(view, params) do
    with lookup when is_function(lookup, 0) <- row_lookup(view, params),
         %{id: reset_id} <- recent_reset(),
         nil <- lookup.() do
      reset_id
    else
      _ -> nil
    end
  end

  defp row_lookup(view, %{"id" => id})
       when view in [CanopyWeb.ChannelLive, CanopyWeb.ChannelLive.Transcript],
       do: fn -> Channels.get(id) end

  defp row_lookup(CanopyWeb.AgentsLive, %{"id" => id}), do: fn -> Agents.get(id) end
  defp row_lookup(CanopyWeb.TeamsLive, %{"id" => id}), do: fn -> Teams.get(id) end

  defp row_lookup(view, %{"id" => id})
       when view in [CanopyWeb.PlaybooksLive, CanopyWeb.PlaybookBuilderLive],
       do: fn -> Playbooks.get(id) end

  defp row_lookup(_view, _params), do: nil

  defp recent_reset do
    case Environment.last_reset() do
      %{status: :done, at: at} = reset -> if recent?(at), do: reset
      %{status: :failed, deleted?: true, at: at} = reset -> if recent?(at), do: reset
      _ -> nil
    end
  end

  defp recent?(at), do: DateTime.diff(DateTime.utc_now(), at) <= @reset_redirect_seconds

  # A page that (re)connects hears of the cards still waiting from the last
  # half hour, in case it missed their notes (asleep, offline). The browser
  # shows only those it never showed or saw (assets/js/notify.js).
  @catch_up_minutes 30

  defp push_pending(socket) do
    if connected?(socket) do
      since = DateTime.add(DateTime.utc_now(), -@catch_up_minutes, :minute)

      case since
           |> Attention.pending_card_events()
           |> Enum.map(&note(socket, &1))
           |> Enum.reject(&is_nil/1) do
        [] -> socket
        notes -> push_event(socket, "canopy:pending", %{notes: notes})
      end
    else
      socket
    end
  end

  @doc "Reloads repositories, channels, and agents for the sidebar."
  def refresh_nav(socket) do
    socket
    |> assign(:repositories, Repositories.list_with_channels())
    |> assign(:dms, Channels.list_dms())
    |> assign(:agents, Agents.list_active())
    |> assign(:schedule_counts, Schedules.active_counts_by_agent())
    |> assign(:hold, Hold.reason())
    |> refresh_palette()
    |> refresh_unread()
    |> refresh_attention()
  end

  # What the command palette lists beyond the sidebar: teams (as `@` rows) and
  # the enabled playbooks (as "Start playbook" commands). Names and ids only.
  defp refresh_palette(socket) do
    assign(socket, :palette, %{
      teams: Enum.map(Teams.list(), &%{id: &1.id, name: &1.name}),
      playbooks: Enum.map(Playbooks.list(enabled: true), &%{id: &1.id, name: &1.name})
    })
  end

  # A step named in the URL, else the first one while setup was never finished
  # or skipped (`Canopy.Settings.onboarded?/0`), else no modal.
  defp setup_step(params) do
    step = if is_map(params), do: CanopyWeb.OnboardingLive.step_for(params["setup"])

    cond do
      step -> step
      Canopy.Settings.onboarded?() -> nil
      true -> "you"
    end
  end

  @sidebar_events ~w(create_section rename_section move_section delete_section toggle_section
                     move_channel archive_channel unarchive_channel dismiss_archive_offer
                     mark_channel_read)

  # Settings → Run setup again: the modal opens over the page, from the start.
  defp handle_event("open_setup", _params, socket) do
    {:halt, assign(socket, :setup, socket.assigns.setup || "you")}
  end

  # The hold banner's Release button lives in the shell, so every page handles it.
  defp handle_event("release_hold", _params, socket) do
    :ok = Hold.release()

    {:halt,
     socket
     |> assign(:hold, nil)
     |> Phoenix.LiveView.put_flash(:info, "Hold released. Reply in a channel to wake its agents.")}
  end

  # The command palette's file search: filenames only, newest first. Fewer
  # than two characters asks for nothing. `seq` comes back so the palette can
  # drop a reply that a later keystroke overtook.
  defp handle_event("cmdk:files", params, socket) do
    q = String.trim(to_string(params["q"]))

    files =
      if String.length(q) < 2 do
        []
      else
        [search: q, limit: 6]
        |> Documents.list()
        |> Enum.map(fn document ->
          %{
            id: document.id,
            filename: document.filename,
            kind: document.kind,
            size_label: Documents.size_label(document.byte_size),
            url: Documents.url_path(document)
          }
        end)
      end

    {:halt, %{files: files, seq: params["seq"]}, socket}
  end

  # `/stop` chosen in the palette for a channel you are not in: the channel
  # step was the confirmation, so it stops at once and says so here.
  defp handle_event("cmdk:stop", params, socket) do
    if Environment.resetting?() do
      {:halt, %{ok: false},
       put_flash(socket, :error, CanopyWeb.EnvironmentComponents.resetting_message())}
    else
      cmdk_stop(params, socket)
    end
  end

  # The palette flipped this browser's desktop notifications switch; the
  # switch itself lives in the browser (assets/js/notify.js).
  defp handle_event("cmdk:notify", %{"on" => on}, socket) do
    message =
      if on == true,
        do: "Desktop notifications are on in this browser.",
        else: "Desktop notifications are off in this browser."

    {:halt, %{}, put_flash(socket, :info, message)}
  end

  # The sidebar's sections and archiving, the offer bar, the Undo toast and the
  # palette, on every page. Each answers `%{ok: true}` or `%{ok: false, error}`
  # and refreshes this tab's nav at once, so the DOM is settled when a hook's
  # reply callback runs; the broadcast refreshes the other tabs.
  defp handle_event(event, params, socket) when event in @sidebar_events do
    if Environment.resetting?() do
      message = CanopyWeb.EnvironmentComponents.resetting_message()
      {:halt, %{ok: false, error: message}, put_flash(socket, :error, message)}
    else
      sidebar_event(event, params, socket)
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp sidebar_event("create_section", %{"repository_id" => repo_id, "name" => name}, socket)
       when is_binary(repo_id) do
    case Sections.create(repo_id, to_string(name)) do
      {:ok, section} -> {:halt, %{ok: true, id: section.id}, refresh_nav(socket)}
      {:error, changeset} -> inline_error(socket, Sections.error_message(changeset))
    end
  end

  defp sidebar_event("rename_section", %{"id" => id, "name" => name}, socket) do
    with_section(socket, id, fn section ->
      case Sections.rename(section, to_string(name)) do
        {:ok, _} -> ok(socket)
        {:error, changeset} -> inline_error(socket, Sections.error_message(changeset))
      end
    end)
  end

  defp sidebar_event("move_section", %{"id" => id, "index" => index}, socket) do
    with_section(socket, id, fn section ->
      case to_index(index) do
        nil ->
          failed(socket, "That position isn't valid.")

        index ->
          section |> Sections.move(index) |> result(socket, "That section no longer exists.")
      end
    end)
  end

  defp sidebar_event("delete_section", %{"id" => id}, socket) do
    with_section(socket, id, fn section ->
      section |> Sections.delete() |> result(socket, "That section couldn't be deleted.")
    end)
  end

  defp sidebar_event("toggle_section", %{"id" => id, "collapsed" => collapsed}, socket) do
    with_section(socket, id, fn section ->
      case to_boolean(collapsed) do
        nil ->
          failed(socket, "That isn't a section state.")

        value ->
          section
          |> Sections.set_collapsed(value)
          |> result(socket, "That section couldn't be saved.")
      end
    end)
  end

  defp sidebar_event("move_channel", %{"id" => id} = params, socket) do
    with_channel(socket, id, fn channel ->
      case params["section_id"] do
        blank when blank in [nil, ""] ->
          channel |> Sections.move_channel(nil) |> move_result(socket)

        section_id ->
          with_section(socket, section_id, fn section ->
            channel |> Sections.move_channel(section) |> move_result(socket)
          end)
      end
    end)
  end

  defp sidebar_event("archive_channel", %{"id" => id}, socket) do
    with_channel(socket, id, fn channel ->
      case Channels.archive(channel) do
        {:ok, channel} ->
          {:halt, %{ok: true},
           socket
           |> refresh_nav()
           |> push_event("canopy:channel_archived", %{id: channel.id, name: channel.name})}

        {:error, _} ->
          failed(socket, "That channel couldn't be archived.")
      end
    end)
  end

  defp sidebar_event("unarchive_channel", %{"id" => id}, socket) do
    with_channel(socket, id, fn channel ->
      channel |> Channels.reopen() |> result(socket, "That channel couldn't be reopened.")
    end)
  end

  defp sidebar_event("dismiss_archive_offer", %{"id" => id}, socket) do
    with_channel(socket, id, fn channel ->
      channel
      |> Channels.dismiss_archive_offer()
      |> result(socket, "That channel couldn't be saved.")
    end)
  end

  # This tab only, as opening the channel does: other tabs clear the dot on
  # their next unread refresh.
  defp sidebar_event("mark_channel_read", %{"id" => id}, socket) do
    with_channel(socket, id, fn channel ->
      :ok = Unread.mark_read(channel.id, Users.local())
      {:halt, %{ok: true}, refresh_unread(socket)}
    end)
  end

  defp sidebar_event(_event, _params, socket), do: failed(socket, "That request was incomplete.")

  defp with_section(socket, id, fun) do
    case Sections.get(id) do
      nil -> failed(refresh_nav(socket), "That section no longer exists.")
      section -> fun.(section)
    end
  end

  defp with_channel(socket, id, fun) do
    case is_binary(id) && Channels.get(id) do
      %Channels.Channel{} = channel -> fun.(channel)
      _ -> failed(refresh_nav(socket), "That channel no longer exists.")
    end
  end

  defp move_result({:error, :dm}, socket), do: failed(socket, "A DM can't go in a section.")

  defp move_result({:error, :other_repository}, socket),
    do: failed(socket, "That section is in another project.")

  defp move_result(result, socket), do: result(result, socket, "That channel couldn't be moved.")

  defp result({:ok, _}, socket, _message), do: ok(socket)
  defp result({:error, :not_found}, socket, message), do: failed(refresh_nav(socket), message)

  defp result({:error, %Ecto.Changeset{} = changeset}, socket, _message),
    do: failed(socket, Sections.error_message(changeset))

  defp result(_error, socket, message), do: failed(socket, message)

  defp ok(socket), do: {:halt, %{ok: true}, refresh_nav(socket)}

  defp failed(socket, message),
    do: {:halt, %{ok: false, error: message}, put_flash(socket, :error, message)}

  # The naming fields show their error inline, so no flash.
  defp inline_error(socket, message), do: {:halt, %{ok: false, error: message}, socket}

  defp to_index(index) when is_integer(index), do: index

  defp to_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_index(_), do: nil

  defp to_boolean(value) when is_boolean(value), do: value
  defp to_boolean("true"), do: true
  defp to_boolean("false"), do: false
  defp to_boolean(_), do: nil

  defp cmdk_stop(%{"channel_id" => id}, socket) when is_binary(id) do
    case Channels.get(id) do
      %{} = channel ->
        if Channels.archived?(channel) do
          {:halt, %{ok: false}, put_flash(socket, :error, "That channel is archived.")}
        else
          {:ok, %{aborted: aborted}} = Runtime.stop_all(channel.id)

          {:halt, %{ok: true},
           put_flash(
             socket,
             :info,
             "Stopped #{stop_label(channel)}: #{aborted} #{if aborted == 1, do: "turn", else: "turns"} aborted. Reply there or press Continue to resume."
           )}
        end

      nil ->
        {:halt, %{ok: false}, put_flash(socket, :error, "That channel no longer exists.")}
    end
  end

  defp cmdk_stop(_params, socket),
    do: {:halt, %{ok: false}, put_flash(socket, :error, "That channel no longer exists.")}

  defp stop_label(%{kind: "dm"} = channel), do: Channels.dm_label(channel)
  defp stop_label(channel), do: "#" <> channel.name

  @doc """
  Reloads the per-channel unread and mention counts for the sidebar, and the
  number of followed threads with unread replies for the rail.
  """
  def refresh_unread(socket) do
    user = Users.local()
    threads = Unread.thread_summary(user)

    socket
    |> assign(:unread, Unread.summary(user))
    |> assign(:threads_unread, map_size(threads))
    # the whole map, so a view that shows per-thread dots needs no query of its own
    |> assign(:thread_unread_summary, threads)
  end

  @doc "Reloads the per-channel cards waiting on the user, for the sidebar."
  def refresh_attention(socket), do: assign(socket, :attention, Attention.summary())

  # Channels created, archived, or reopened anywhere (including DMs agents
  # open) show up in every sidebar without a reload.
  defp handle_info({:channels, :changed}, socket), do: {:halt, refresh_nav(socket)}

  # A message anywhere may change the unread marks. The channel view sees its
  # own copy of the event first and marks the channel read, so this refresh
  # already reflects that.
  defp handle_info({:timeline_any, %{event_type: "message"} = event}, socket),
    do: {:halt, socket |> refresh_unread() |> notify(event)}

  # A thread read, followed, or unfollowed elsewhere (another tab): the badge
  # follows, and the page may want it too (dots, the inbox).
  defp handle_info({:thread_reads, _root_id}, socket), do: {:cont, refresh_unread(socket)}

  # A question or permission card raised, answered, or detached anywhere: the
  # "needs you" badges follow, so a card in a channel nobody is looking at is seen.
  defp handle_info({:timeline_any, %{event_type: "question_" <> _} = event}, socket),
    do: {:halt, socket |> refresh_attention() |> notify(event)}

  # An auto-approval clears a badge only when a grant swept a waiting card (it
  # then names the request); the rest change no card, so nothing is read.
  defp handle_info(
         {:timeline_any, %{event_type: "permission_auto_approved", payload: payload}},
         socket
       ) do
    if Map.has_key?(payload, "request_id"),
      do: {:halt, refresh_attention(socket)},
      else: {:halt, socket}
  end

  defp handle_info({:timeline_any, %{event_type: "permission_" <> _} = event}, socket),
    do: {:halt, socket |> refresh_attention() |> notify(event)}

  # Sign-off cards too: a freestanding card has no run broadcast to refresh the badge.
  defp handle_info({:timeline_any, %{event_type: "signoff_" <> _} = event}, socket),
    do: {:halt, socket |> refresh_attention() |> notify(event)}

  # A sign-off requested or a task completed: a desktop notification may say
  # so. The page may want the event too.
  defp handle_info({:timeline_any, %{event_type: type} = event}, socket)
       when type in ~w(playbook_approval_requested task_updated),
       do: {:cont, notify(socket, event)}

  # A channel's run of turns is over: "Work finished", when the browser wants it.
  defp handle_info({:channel_quiet, _channel_id, _info} = signal, socket),
    do: {:halt, notify(socket, signal)}

  # Schedule changes update the sidebar counts; the page may also want the event.
  defp handle_info({:hold, _what}, socket), do: {:halt, assign(socket, :hold, Hold.reason())}

  # A run started, finished, or held for a sign-off: the glyph and the badge
  # follow; the channel view may want it too.
  defp handle_info({:playbook_runs, :changed, _channel_id}, socket),
    do: {:cont, refresh_attention(socket)}

  # A team or a playbook changed: the palette's lists follow. Pages that list
  # them subscribe themselves and want the event too.
  defp handle_info({:teams, :changed}, socket), do: {:cont, refresh_palette(socket)}
  defp handle_info({:playbooks, :changed}, socket), do: {:cont, refresh_palette(socket)}

  defp handle_info({:schedules, :changed, _channel_id}, socket),
    do: {:cont, assign(socket, :schedule_counts, Schedules.active_counts_by_agent())}

  # The setup modal closed (Skip, Look around, Start a channel): the page
  # navigates, live, so it is mounted again with what was chosen (and its
  # pickers, which the modal's would have duplicated, come back).
  defp handle_info({:canopy_setup, :close, opts}, socket) do
    socket = assign(socket, :setup, nil)
    socket = if opts[:flash], do: put_flash(socket, :info, opts[:flash]), else: socket
    {:halt, push_navigate(socket, to: opts[:to] || without_setup(socket))}
  end

  # A reset that deleted something: the rows behind every page (sidebar,
  # palette, drafts kept in the browser) are gone, so every tab reloads onto
  # the banner. A full page load, not a live navigation.
  defp handle_info({:environment, {:reset_done, %{id: id}}}, socket),
    do: {:halt, redirect(socket, to: ~p"/settings?reset=#{id}")}

  defp handle_info({:environment, {:reset_failed, %{id: id, deleted?: true}}}, socket),
    do: {:halt, redirect(socket, to: ~p"/settings?reset=#{id}")}

  # Steps, and failures that deleted nothing, are Settings' alone; other
  # pages have no handle_info for them.
  defp handle_info({:environment, _message}, %{view: CanopyWeb.SettingsLive} = socket),
    do: {:cont, socket}

  defp handle_info({:environment, _message}, socket), do: {:halt, socket}

  defp handle_info(_message, socket), do: {:cont, socket}

  # The page as it is, minus `?setup=`, so a reload doesn't open setup again.
  defp without_setup(socket) do
    uri = URI.parse(socket.private[:canopy_uri] || socket.assigns[:current_path] || "/")

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.delete("setup")

    if query == %{},
      do: uri.path || "/",
      else: (uri.path || "/") <> "?" <> URI.encode_query(query)
  end

  # The page decides whether to show it (`assets/js/notify.js`); the channel
  # comes from what the sidebar already holds.
  defp notify(socket, signal) do
    case note(socket, signal) do
      nil -> socket
      note -> push_event(socket, "canopy:notify", note)
    end
  end

  defp note(socket, signal) do
    channel_id =
      case signal do
        {:channel_quiet, channel_id, _info} -> channel_id
        %{channel_id: channel_id} -> channel_id
      end

    Notify.classify(signal, %{
      channel: known_channel(socket.assigns, channel_id) || Channels.get(channel_id),
      names: Map.new(socket.assigns.agents, &{&1.id, &1.name})
    })
  end

  defp known_channel(assigns, channel_id) do
    Enum.find(assigns.dms, &(&1.id == channel_id)) ||
      Enum.find_value(assigns.repositories, fn repository ->
        Enum.find(repository.channels, &(&1.id == channel_id))
      end)
  end

  defp handle_params(params, uri, socket) do
    path = URI.parse(uri).path || "/"

    channel_id = channel_id_from(path, params)
    channel = channel_id && Channels.get(channel_id)

    socket =
      socket
      |> put_private(:canopy_uri, uri)
      |> assign(:current_path, path)
      |> assign(:current_channel_id, channel_id)
      |> assign(:current_repository_id, channel && channel.repository_id)

    {:cont, socket}
  end

  defp channel_id_from("/channels/" <> _, %{"id" => id}), do: id
  defp channel_id_from(_, _), do: nil
end
