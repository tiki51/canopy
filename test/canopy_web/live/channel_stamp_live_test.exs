defmodule CanopyWeb.ChannelStampLiveTest do
  @moduledoc """
  Dated message stamps on the channel page: in the feed, in a DM and in the
  thread panel, and a message that arrives while the page is open. The
  formatting rules are in `components/stamp_test.exs`.
  """
  use CanopyWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest

  alias Canopy.{Channels, Fixtures, Messages, Repo, Runtime}
  alias Canopy.OpenCode.ClientMock, as: OC
  alias CanopyWeb.{ChannelLive, TimelineComponents}

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
    stub(OC, :messages, fn _dir, _sid, _query, _opts -> {:ok, []} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> Fixtures.unique_suffix()}}
    end)

    Canopy.MCP.mark_registered(scenario.repository.id)
    on_exit(fn -> Runtime.stop_channel(scenario.channel.id) end)
    scenario
  end

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  defp backdate(message, at),
    do: Repo.update_all(where(Messages.Message, id: ^message.id), set: [inserted_at: at])

  # the stamp's {text, title} under `scope`, found by its datetime
  defp stamp(view, scope, at) do
    time =
      view
      |> element("#{scope} time[datetime='#{DateTime.to_iso8601(at)}']")
      |> render()
      |> LazyHTML.from_fragment()

    {time |> LazyHTML.text() |> String.trim(), time |> LazyHTML.attribute("title") |> hd()}
  end

  test "the feed dates older messages and keeps today's as the time", ctx do
    %{conn: conn, channel: channel, user: user} = ctx
    {:ok, old} = Messages.post_user_message(channel.id, user.id, "Two days back")
    {:ok, today} = Messages.post_user_message(channel.id, user.id, "Just now")
    at = ago(2)
    backdate(old, at)

    {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}")

    {text, title} = stamp(view, "#message-#{old.id}", at)
    assert text == TimelineComponents.stamp_text(at)
    assert text =~ ~r/^[A-Z][a-z]{2} \d{2}:\d{2}$/
    assert title == TimelineComponents.stamp_title(at)

    {text, title} = stamp(view, "#message-#{today.id}", today.inserted_at)
    assert text =~ ~r/^\d{2}:\d{2}$/
    assert title == TimelineComponents.stamp_title(today.inserted_at)
  end

  test "a DM dates its messages the same way", ctx do
    %{conn: conn, repository: repository, agent: agent, user: user} = ctx
    {:ok, dm} = Channels.ensure_dm(repository.id, agent)
    on_exit(fn -> Runtime.stop_channel(dm.id) end)
    {:ok, old} = Messages.post_user_message(dm.id, user.id, "From yesterday")
    at = ago(1)
    backdate(old, at)

    {:ok, view, _html} = live(conn, ~p"/channels/#{dm.id}")

    {text, title} = stamp(view, "#message-#{old.id}", at)
    assert text =~ ~r/^Yesterday \d{2}:\d{2}$/
    assert title == TimelineComponents.stamp_title(at)
  end

  test "the thread panel dates the root and its replies", ctx do
    %{conn: conn, channel: channel, user: user, agent: agent} = ctx
    {:ok, root} = Messages.post_user_message(channel.id, user.id, "Why is checkout slow?")
    {:ok, reply} = Messages.thread_reply(root.id, {:agent, agent.id}, "The pricing call.")
    root_at = ago(10)
    reply_at = ago(3)
    backdate(root, root_at)
    backdate(reply, reply_at)

    {:ok, view, _html} = live(conn, ChannelLive.thread_path(channel.id, root.id, nil))

    {text, _} = stamp(view, "#thread-msg-#{reply.id}", reply_at)
    assert text == TimelineComponents.stamp_text(reply_at)
    assert text =~ ~r/^[A-Z][a-z]{2} \d{2}:\d{2}$/

    {text, _} = stamp(view, "#thread-msg-#{root.id}", root_at)
    assert text =~ ~r/^[A-Z][a-z]{2} \d{1,2}(, \d{4})?, \d{2}:\d{2}$/
    # the same root in the feed reads the same
    assert {^text, _} = stamp(view, "#message-#{root.id}", root_at)
  end

  test "a message that arrives while the page is open is stamped as today", ctx do
    %{conn: conn, channel: channel, user: user} = ctx
    {:ok, view, _html} = live(conn, ~p"/channels/#{channel.id}")

    {:ok, message} = Messages.post_user_message(channel.id, user.id, "Arrived live")
    assert has_element?(view, "#message-#{message.id}", "Arrived live")

    {text, title} = stamp(view, "#message-#{message.id}", message.inserted_at)
    assert text =~ ~r/^\d{2}:\d{2}$/
    assert title == TimelineComponents.stamp_title(message.inserted_at)
  end
end
