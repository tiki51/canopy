defmodule CanopyWeb.ChannelHereLiveTest do
  @moduledoc """
  `@here` in the channel page: the composer's roster (`data-here`), the reach
  pill under a message whose `@here` resolved, the accent chip, and the
  reserved-name warning on the agent and team forms. Who `@here` wakes is the
  backend's (`Canopy.Messages.resolve_mentions/2`); this checks what the page
  shows of it.
  """
  use CanopyWeb.ConnCase, async: false

  import Ecto.Query, only: [where: 2]
  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Agents, Channels, Fixtures, Messages, Repo, Runtime}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias CanopyWeb.{ChannelLive, Markdown}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    reviewer = Fixtures.agent_fixture(%{name: "reviewer#{Fixtures.unique_suffix()}"})
    scenario = Fixtures.scenario(members: [reviewer])

    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)

    stub(OC, :add_mcp, fn _dir, _name, _config, _opts ->
      {:ok, %{"canopy" => %{"status" => "connected"}}}
    end)

    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    stub(OC, :messages, fn _dir, _sid, _query, _opts -> {:ok, []} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
    end)

    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    Map.put(scenario, :reviewer, reviewer)
  end

  defp open(conn, channel), do: live(conn, ~p"/channels/#{channel.id}")

  defp roster(view, form \\ "#composer-form") do
    [_, value] = Regex.run(~r/data-here="([^"]*)"/, view |> element(form) |> render())
    value |> unescape() |> Jason.decode!()
  end

  defp unescape(html),
    do:
      html
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&amp;", "&")

  defp member_names(channel), do: channel |> Channels.members() |> Enum.map(& &1.name)

  describe "the composer's @here roster" do
    test "data-here lists the members in name order, with who is off", ctx do
      %{channel: channel, reviewer: reviewer} = ctx
      off = Fixtures.agent_fixture(%{name: "zz-off#{Fixtures.unique_suffix()}"})
      {:ok, _} = Channels.add_agent(channel, off)
      {:ok, _} = Agents.deactivate(off)

      {:ok, view, _html} = open(conn_of(ctx), channel)

      roster = roster(view)
      active = for %{"active" => true, "name" => name} <- roster, do: name
      assert active == Enum.sort(active)
      assert reviewer.name in active
      assert ctx.agent.name in active
      assert %{"name" => off.name, "active" => false, "working" => false} in roster
      assert List.last(roster)["name"] == off.name

      assert has_element?(view, "#composer-form[data-channel-name='#{channel.name}']")
      refute has_element?(view, "#composer-form[data-dm]")
      assert has_element?(view, "#composer-here-hint[aria-live='polite']")
      assert has_element?(view, "#composer-input[data-here-hint='#composer-here-hint']")
    end

    test "a member who goes off, or leaves, drops out of data-here", ctx do
      %{channel: channel, reviewer: reviewer} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)
      assert %{"name" => reviewer.name, "active" => true, "working" => false} in roster(view)

      # Agents.deactivate/1 broadcasts {:agents, :changed}
      {:ok, _} = Agents.deactivate(reviewer)
      assert %{"name" => reviewer.name, "active" => false, "working" => false} in roster(view)

      {:ok, _} = Agents.update(Agents.get!(reviewer.id), %{active: true})
      assert %{"name" => reviewer.name, "active" => true, "working" => false} in roster(view)
    end

    test "an agent created after mount reaches the composer and the pill", ctx do
      %{channel: channel, user: user} = ctx
      {:ok, view, _html} = open(conn_of(ctx), channel)

      late = Fixtures.agent_fixture(%{name: "late#{Fixtures.unique_suffix()}", color: "#7c3aed"})
      assert has_element?(view, "#composer-form[data-agents*='#{late.name}']")

      view |> form("#composer-form", message: %{body: "/i @#{late.name}"}) |> render_submit()
      assert Enum.any?(roster(view), &(&1["name"] == late.name))

      Canopy.Timeline.subscribe(channel.id)
      {:ok, message} = Messages.post_user_message(channel.id, user.id, "@here standup")
      assert_receive {:timeline, %{event_type: "message"}}, 2_000
      assert view |> element("#message-#{message.id}") |> render() =~ "woke"
      pill = "#message-here-#{message.id}"
      assert has_element?(view, "#{pill} [title='@#{late.name}']")
      refute has_element?(view, "#{pill} [title='#{user.display_name}']")
    end

    test "a DM's composers say so; the thread composer carries the same roster", ctx do
      %{agent: agent, reviewer: reviewer, repository: repository, user: user} = ctx
      {:ok, dm} = Channels.ensure_dm(repository.id, [agent, reviewer])
      {:ok, root} = Messages.post_user_message(dm.id, user.id, "a question")

      {:ok, view, _html} = live(conn_of(ctx), ChannelLive.thread_path(dm.id, root.id, nil))
      assert has_element?(view, "#composer-form[data-dm='true']")
      assert has_element?(view, "#thread-composer-form[data-dm='true'][data-thread='true']")
      assert roster(view, "#thread-composer-form") == roster(view)
      assert length(roster(view)) == 2
    end
  end

  describe "the reach pill" do
    test "a user's @here shows who it woke, with no chatter budget", ctx do
      %{channel: channel, user: user} = ctx
      {:ok, message} = Messages.post_user_message(channel.id, user.id, "@here standup in 5")
      entry = Messages.here_mention(message)
      count = length(entry["reach"])
      assert count == length(member_names(channel))

      {:ok, view, _html} = open(conn_of(ctx), channel)
      pill = "#message-here-#{message.id}"
      assert has_element?(view, pill, "woke #{count} agents")
      refute has_element?(view, pill, "chatter budget")
      assert has_element?(view, "#{pill}-list li", ctx.reviewer.name)
      assert has_element?(view, "#{pill}[phx-mounted]")

      html = view |> element("#message-#{message.id}") |> render()
      assert html =~ ~s(<span class="#{Markdown.here_class()}">@here</span>)
    end

    test "an agent's @here costs one chatter turn; named directly, it costs none", ctx do
      %{channel: channel, agent: agent, reviewer: reviewer} = ctx
      {:ok, charged} = Messages.post_agent_message(channel.id, agent.id, "@here please review")

      {:ok, free} =
        Messages.post_agent_message(channel.id, agent.id, "@here @#{reviewer.name} please")

      {:ok, view, _html} = open(conn_of(ctx), channel)

      assert has_element?(
               view,
               "#message-here-#{charged.id}",
               "woke 1 agent · 1 turn of chatter budget"
             )

      assert has_element?(view, "#message-here-#{free.id}", "woke 1 agent")
      refute has_element?(view, "#message-here-#{free.id}", "chatter budget")
    end

    test "past five agents the pill shows +N; members who are off are listed muted", ctx do
      %{channel: channel, user: user} = ctx

      for n <- 1..5 do
        agent = Fixtures.agent_fixture(%{name: "crew#{n}-#{Fixtures.unique_suffix()}"})
        {:ok, _} = Channels.add_agent(channel, agent)
      end

      off = Fixtures.agent_fixture(%{name: "off#{Fixtures.unique_suffix()}"})
      {:ok, _} = Channels.add_agent(channel, off)
      {:ok, _} = Agents.deactivate(off)

      {:ok, message} = Messages.post_user_message(channel.id, user.id, "@here all hands")
      reach = length(Messages.here_mention(message)["reach"])
      assert reach == 7

      {:ok, view, _html} = open(conn_of(ctx), channel)
      pill = "#message-here-#{message.id}"
      assert has_element?(view, pill, "+2")
      assert has_element?(view, pill, "woke 7 agents")
      assert has_element?(view, "#{pill}-list li", "@#{off.name}: off, not woken")
      # the off member's avatar is muted too; the reached ones aren't
      assert view |> element("#{pill}-list") |> render() |> String.split("grayscale") |> length() ==
               2
    end

    test "an @here that reached nobody says so", ctx do
      %{agent: agent, repository: repository} = ctx
      {:ok, dm} = Channels.ensure_dm(repository.id, agent)
      {:ok, message} = Messages.post_agent_message(dm.id, agent.id, "@here anyone?")
      assert Messages.here_mention(message)["reach"] == []

      {:ok, view, _html} = open(conn_of(ctx), dm)

      assert has_element?(
               view,
               "#message-here-#{message.id}",
               "@here woke nobody: no other agents in this DM."
             )

      channel = Fixtures.channel_fixture(repository_id: repository.id, owner_agent_id: agent.id)
      assert member_names(channel) == [agent.name]
      {:ok, message} = Messages.post_agent_message(channel.id, agent.id, "@here anyone?")
      on_exit(fn -> Runtime.stop_channel(channel.id) end)

      {:ok, view, _html} = open(conn_of(ctx), channel)

      assert has_element?(
               view,
               "#message-here-#{message.id}",
               "@here woke nobody: no other agents in this channel."
             )
    end

    test "a thread reply's @here shows the whole channel in the panel", ctx do
      %{channel: channel, user: user, agent: agent} = ctx
      {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "the plan")
      {:ok, reply} = Messages.thread_reply(root.id, {:user, user.id}, "@here thoughts?")
      count = length(member_names(channel))

      {:ok, view, _html} = live(conn_of(ctx), ChannelLive.thread_path(channel.id, root.id, nil))
      assert has_element?(view, "#thread-msg-here-#{reply.id}", "woke #{count} agents")
    end

    test "an id with no agent draws a ? avatar, not the user's", ctx do
      %{channel: channel, user: user} = ctx
      {:ok, message} = Messages.post_user_message(channel.id, user.id, "@here hello")
      entry = Messages.here_mention(message)
      ghost = "agt_gone#{Fixtures.unique_suffix()}"
      entries = message.team_mentions -- [entry]
      entry = %{entry | "reach" => entry["reach"] ++ [ghost]}

      {1, _} =
        Repo.update_all(
          where(Messages.Message, id: ^message.id),
          set: [team_mentions: entries ++ [entry]]
        )

      {:ok, view, _html} = open(conn_of(ctx), channel)
      pill = "#message-here-#{message.id}"
      assert has_element?(view, "#{pill} [title='unknown agent']", "?")
      assert has_element?(view, "#{pill}-list li", "unknown agent")
      refute has_element?(view, "#{pill} [title='#{user.display_name}']")
    end

    test "no pill and no chip for @here in code, in a turn's final text, or with no entry", ctx do
      %{channel: channel, user: user, agent: agent} = ctx
      {:ok, code} = Messages.post_user_message(channel.id, user.id, "type `@here` to wake all")
      {:ok, final} = Messages.post_agent_reply(channel.id, agent.id, "I told @here about it")

      {:ok, old} =
        Messages.post_user_message(channel.id, user.id, "@here an old one", mentions: [])

      for message <- [code, final, old], do: assert(Messages.here_mention(message) == nil)

      {:ok, view, _html} = open(conn_of(ctx), channel)

      for message <- [code, final, old] do
        refute has_element?(view, "#message-here-#{message.id}")
        refute view |> element("#message-#{message.id}") |> render() =~ Markdown.here_class()
      end
    end
  end

  test "the paused bar counts its turns in the singular too", ctx do
    {:ok, _} = Canopy.Settings.update(%{chatter_pause: true, chatter_limit: 1})
    {:ok, view, _html} = open(conn_of(ctx), ctx.channel)

    Phoenix.PubSub.broadcast(
      Canopy.PubSub,
      Canopy.Timeline.topic(ctx.channel.id),
      {:chatter, :paused}
    )

    assert has_element?(view, "#paused-bar", "Paused after 1 agent turn without you.")
  end

  describe "a pre-existing agent or team named here" do
    test "its edit form warns; others don't", ctx do
      %{reviewer: reviewer} = ctx
      # the agent form loads the engine's models and agents asynchronously
      stub(OC, :providers, fn _opts -> {:ok, %{"providers" => [], "default" => %{}}} end)
      stub(OC, :agents, fn _dir, _opts -> {:ok, []} end)
      legacy = Fixtures.agent_fixture(%{name: "legacy#{Fixtures.unique_suffix()}"})
      team = Fixtures.team_fixture([reviewer], name: "squad#{Fixtures.unique_suffix()}")

      {:ok, view, _html} = live(conn_of(ctx), ~p"/agents/#{legacy.id}/edit")
      refute has_element?(view, "#agent-reserved-name")

      {1, _} =
        Repo.update_all(where(Agents.Agent, id: ^legacy.id), set: [name: "here"])

      {1, _} =
        Repo.update_all(where(Canopy.Teams.Team, id: ^team.id), set: [name: "Here"])

      {:ok, view, _html} = live(conn_of(ctx), ~p"/agents/#{legacy.id}/edit")
      assert has_element?(view, "#agent-reserved-name", "can't be mentioned by name")
      assert has_element?(view, "#agent-reserved-name", "this agent")

      {:ok, view, _html} = live(conn_of(ctx), ~p"/teams/#{team.id}/edit")
      assert has_element?(view, "#team-reserved-name", "this team")
    end
  end

  defp conn_of(%{conn: conn}), do: conn
end
