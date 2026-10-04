defmodule CanopyWeb.ThreadsLiveTest do
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Fixtures, Messages, Runtime}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias CanopyWeb.ChannelLive

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    scenario = Fixtures.scenario()

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    Canopy.MCP.mark_registered(scenario.repository.id)

    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    scenario
  end

  test "Following lists the threads you follow with their latest replies; Open thread goes there",
       ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    {:ok, mine} = Messages.post_user_message(channel.id, user.id, "Why is checkout slow?")
    {:ok, theirs} = Messages.post_agent_message(channel.id, agent.id, "An unrelated finding")
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "The pricing call runs twice.")
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "Caching it fixes p95.")
    {:ok, _} = Messages.thread_reply(theirs.id, {:agent, agent.id}, "Nobody follows this one.")

    {:ok, view, _html} = live(ctx.conn, ~p"/threads")

    row = "#thread-row-#{mine.id}"
    assert has_element?(view, row, "Why is checkout slow?")
    assert has_element?(view, row, "The pricing call runs twice.")
    assert has_element?(view, row, "Caching it fixes p95.")
    assert has_element?(view, row, "2 replies")
    assert has_element?(view, "#{row}-unread", "2 new")
    refute has_element?(view, "#thread-row-#{theirs.id}")
    # the rail and the tab carry the count of followed threads with unread replies
    assert has_element?(view, "#rail-threads-badge", "1")
    assert has_element?(view, "#threads-tab-following-count", "1")

    # a new reply anywhere refreshes the rows
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "Shipped.")
    assert has_element?(view, row, "Shipped.")
    assert has_element?(view, "#{row}-unread", "3 new")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#{row}-open") |> render_click()

    assert to == ChannelLive.thread_path(channel.id, mine.id)

    # opening the thread reads it: the badge clears
    {:ok, channel_view, _html} = live(ctx.conn, to)
    assert has_element?(channel_view, "#thread-panel")
    refute has_element?(channel_view, "#rail-threads-badge")

    {:ok, view, _html} = live(ctx.conn, ~p"/threads")
    refute has_element?(view, "#{row}-unread")
    refute has_element?(view, "#rail-threads-badge")
  end

  test "a row's root and replies are one line of plain text, not Markdown", ctx do
    %{channel: channel, agent: agent, user: user} = ctx

    {:ok, root} =
      Messages.post_user_message(channel.id, user.id, "## Why is `checkout` **slow**?")

    {:ok, _} =
      Messages.thread_reply(
        root.id,
        {:agent, agent.id},
        "- **Root cause.** see [the PR](https://x.test/1)"
      )

    {:ok, view, _html} = live(ctx.conn, ~p"/threads")

    row = element(view, "#thread-row-#{root.id}")
    assert render(row) =~ "Why is checkout slow?"
    assert render(row) =~ "Root cause. see the PR"
    refute render(row) =~ "**"
    refute render(row) =~ "](https"
  end

  test "All active lists every thread with a recent reply; an empty tab says so", ctx do
    %{channel: channel, agent: agent} = ctx

    {:ok, view, _html} = live(ctx.conn, ~p"/threads")
    assert has_element?(view, "#threads-empty", "No threads followed")

    {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "A finding")
    {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "More detail.")

    view |> element("#threads-tab-active") |> render_click()
    assert_patch(view, ~p"/threads?tab=active")
    assert has_element?(view, "#thread-row-#{root.id}", "More detail.")
    refute has_element?(view, "#threads-empty")
  end

  test "Agents working lists the threads an agent is working in right now", ctx do
    %{channel: channel, agent: agent} = ctx
    {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")

    {:ok, view, _html} = live(ctx.conn, ~p"/threads?tab=working")
    assert has_element?(view, "#threads-empty", "No agent is working in a thread")

    {:ok, pid} = Runtime.ensure_channel(channel.id, start_stream: false)
    {:ok, _} = Runtime.post_user_message(channel.id, "and on mobile?", thread_id: root.id)
    # the channel's process has started the turn, and told the inbox, once it
    # has handled the reply
    _ = :sys.get_state(pid)

    assert has_element?(view, "#thread-row-#{root.id}-working", "@#{agent.name} is replying")
  end

  test "a DM thread is labelled with its agents, not the DM's slug", ctx do
    %{agent: agent, repository: repository} = ctx
    {:ok, dm} = Canopy.Channels.ensure_dm(repository.id, agent)
    {:ok, root} = Messages.post_agent_message(dm.id, agent.id, "In our DM")
    {:ok, _} = Messages.thread_reply(root.id, {:agent, agent.id}, "More.")

    {:ok, view, _html} = live(ctx.conn, ~p"/threads?tab=active")
    assert has_element?(view, "#thread-row-#{root.id}", "@#{agent.name}")
    refute has_element?(view, "#thread-row-#{root.id}", dm.name)
  end

  test "the working set follows turn messages without asking the channels", ctx do
    %{channel: channel, agent: agent} = ctx
    {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "Which width?")

    {:ok, view, _html} = live(ctx.conn, ~p"/threads?tab=working")
    assert has_element?(view, "#threads-empty")

    # no channel server runs: the payload alone puts the thread on the list
    refute Canopy.Runtime.Supervisor.whereis(channel.id)

    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      "threads",
      {:thread_turn, channel.id, agent.id, root.id}
    )

    assert has_element?(view, "#thread-row-#{root.id}-working", "@#{agent.name} is replying")

    Phoenix.PubSub.broadcast(Canopy.PubSub, "threads", {:thread_turn, channel.id, agent.id, nil})
    assert has_element?(view, "#threads-empty")
  end

  test "a thread read in another view clears the row's unread count", ctx do
    %{channel: channel, agent: agent, user: user} = ctx
    {:ok, mine} = Messages.post_user_message(channel.id, user.id, "Mine")
    {:ok, _} = Messages.thread_reply(mine.id, {:agent, agent.id}, "An answer.")

    {:ok, view, _html} = live(ctx.conn, ~p"/threads")
    assert has_element?(view, "#thread-row-#{mine.id}-unread", "1 new")

    :ok = Canopy.Threads.mark_read(mine.id, user)
    refute has_element?(view, "#thread-row-#{mine.id}-unread")
    refute has_element?(view, "#rail-threads-badge")
  end
end
