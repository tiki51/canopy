defmodule CanopyWeb.ChannelHereEdgesLiveTest do
  @moduledoc """
  `@here` on the channel page at its edges: the chip keeps the typed case and
  sits next to a name's chip, a thread reply also sent to the channel has a
  pill in both places with distinct ids, and the outsider hint ignores the
  `here` entry. The main cases are in `channel_here_live_test.exs`.
  """
  use CanopyWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Channels, Fixtures, Messages, Runtime}
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

  test "the chip keeps the typed case and sits beside a name's chip", ctx do
    %{conn: conn, channel: channel, user: user, reviewer: reviewer} = ctx

    {:ok, message} =
      Messages.post_user_message(channel.id, user.id, "@Here and @#{reviewer.name}, look")

    {:ok, view, _html} = open(conn, channel)
    html = view |> element("#message-#{message.id}") |> render()

    assert html =~ ~s(<span class="#{Markdown.here_class()}">@Here</span>)
    assert html =~ ~s(<span class="#{Markdown.mention_class()}">@#{reviewer.name}</span>)
  end

  test "an agent's @here pill for exactly one agent is singular", ctx do
    %{conn: conn, channel: channel, agent: agent} = ctx
    {:ok, message} = Messages.post_agent_message(channel.id, agent.id, "@here one of you")

    {:ok, view, _html} = open(conn, channel)

    assert has_element?(view, "#message-here-#{message.id}", "woke 1 agent")
    refute has_element?(view, "#message-here-#{message.id}", "woke 1 agents")
  end

  test "a thread reply sent to the channel has a pill in the feed and the panel, ids distinct",
       ctx do
    %{conn: conn, channel: channel, user: user, agent: agent} = ctx
    {:ok, root} = Messages.post_agent_message(channel.id, agent.id, "the plan")

    {:ok, reply} =
      Messages.thread_reply(root.id, {:user, user.id}, "@here decide", to_channel: true)

    {:ok, view, html} = live(conn, ChannelLive.thread_path(channel.id, root.id, nil))

    assert has_element?(view, "#thread-msg-here-#{reply.id}")
    ids = Regex.scan(~r/id="([^"]*here-#{reply.id})"/, html) |> Enum.map(&List.last/1)
    assert ids == Enum.uniq(ids)
  end

  test "system notes never show a pill", ctx do
    %{conn: conn, channel: channel, user: user} = ctx
    {:ok, note} = Messages.post_user_note(channel.id, user.id, "@here was mentioned in a note")

    {:ok, view, _html} = open(conn, channel)
    refute has_element?(view, "#message-here-#{note.id}")
  end

  test "the outsider hint names the outsider and ignores the @here entry", ctx do
    %{conn: conn, channel: channel} = ctx
    outsider = Fixtures.agent_fixture(%{name: "outsider#{Fixtures.unique_suffix()}"})

    {:ok, view, _html} = open(conn, channel)

    view
    |> form("#composer-form", message: %{body: "@here and @#{outsider.name}"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "@#{outsider.name} is not in this channel")
    assert has_element?(view, "#flash-info", "/i @#{outsider.name}")
    refute has_element?(view, "#flash-info", "/i @here")
    assert Channels.members(channel) |> Enum.all?(&(&1.id != outsider.id))
  end
end
