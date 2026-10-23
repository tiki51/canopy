defmodule Canopy.MessagesHereEdgesTest do
  @moduledoc """
  `@here` resolution at its edges: senders outside the channel, DMs from an
  agent, punctuation, repeats, overridden mentions, commands, and the
  user-mention flag. The main cases are in `messages_test.exs`.
  """
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Mox

  alias Canopy.{Channels, Messages, Runtime}
  alias Canopy.OpenCode.ClientMock, as: OC

  setup :set_mox_global

  setup do
    stub(OC, :mcp_status, fn _dir, _opts -> {:ok, %{"canopy" => %{"status" => "connected"}}} end)
    stub(OC, :add_mcp, fn _dir, _name, _config, _opts -> {:ok, %{}} end)
    stub(OC, :dispose_instance, fn _dir, _opts -> {:ok, true} end)
    stub(OC, :prompt_async, fn _dir, _sid, _body, _opts -> {:ok, ""} end)
    stub(OC, :messages, fn _dir, _sid, _query, _opts -> {:ok, []} end)

    stub(OC, :create_session, fn _dir, _body, _opts ->
      {:ok, %{"id" => "ses_" <> unique_suffix()}}
    end)

    ctx = scenario()
    zed = agent_fixture(%{name: "zed-" <> unique_suffix()})
    amy = agent_fixture(%{name: "amy-" <> unique_suffix()})
    gone = agent_fixture(%{name: "gone-" <> unique_suffix()})

    for agent <- [zed, amy, gone], do: {:ok, _} = Channels.add_agent(ctx.channel, agent)
    {:ok, gone} = Canopy.Agents.deactivate(gone)

    on_exit(fn -> Runtime.stop_channel(ctx.channel.id) end)
    Map.merge(ctx, %{zed: zed, amy: amy, gone: gone})
  end

  defp ids_by_name(agents), do: agents |> Enum.sort_by(& &1.name) |> Enum.map(& &1.id)

  defp post(ctx, body), do: Messages.post_user_message(ctx.channel.id, ctx.user.id, body)

  test "an agent outside the channel reaches every active member", ctx do
    outsider = agent_fixture(%{name: "out-" <> unique_suffix()})

    {:ok, message} = Messages.post_agent_message(ctx.channel.id, outsider.id, "@here hi")

    assert Messages.here_mention(message)["reach"] == ids_by_name([ctx.agent, ctx.zed, ctx.amy])
  end

  test "skipped holds inactive members only, not every inactive agent", ctx do
    elsewhere = agent_fixture(%{name: "else-" <> unique_suffix()})
    {:ok, _} = Canopy.Agents.deactivate(elsewhere)

    {:ok, message} = post(ctx, "@here")

    assert Messages.here_mention(message)["skipped"] == [ctx.gone.id]
  end

  test "the entry is fixed at post time; a later member isn't added", ctx do
    {:ok, message} = post(ctx, "@here")
    late = agent_fixture(%{name: "late-" <> unique_suffix()})
    {:ok, _} = Channels.add_agent(ctx.channel, late)

    refute late.id in Messages.here_mention(Messages.get!(message.id))["reach"]
  end

  test "an agent's @here in a DM reaches the DM's other agents", ctx do
    {:ok, dm} = Channels.ensure_dm(ctx.repository.id, [ctx.zed, ctx.amy])

    {:ok, message} = Messages.post_agent_message(dm.id, ctx.zed.id, "@here ping")

    assert Messages.here_mention(message)["reach"] == [ctx.amy.id]
  end

  test "punctuation, bold and quotes around @here still count", ctx do
    for body <- [
          "@here,",
          "@here.",
          "(@here)",
          "@here!",
          "@here's",
          "**@here**",
          "*@here*",
          "> @here"
        ] do
      assert Messages.here?(body), body
      {:ok, message} = post(ctx, body)
      assert Messages.here_mention(message), body
    end
  end

  test "longer names and addresses are not @here", ctx do
    for body <- ~w(@hereafter @heres @here-x @here_x foo@here.com @@here x@here) do
      refute Messages.here?(body), body
      {:ok, message} = post(ctx, body)
      assert Messages.here_mention(message) == nil, body
    end
  end

  test "@here twice gives one entry", ctx do
    {:ok, message} = post(ctx, "@here and again @HERE")

    assert [%{"name" => "here"}] = message.team_mentions
    assert message.mentions == Enum.uniq(message.mentions)
  end

  test "an inactive agent named directly stays out of reach", ctx do
    {:ok, message} = post(ctx, "@#{ctx.gone.name} @here")

    here = Messages.here_mention(message)
    refute ctx.gone.id in here["reach"]
    assert here["skipped"] == [ctx.gone.id]
  end

  test "overridden mentions (a user note) never resolve @here", ctx do
    {:ok, note} = Messages.post_user_note(ctx.channel.id, ctx.user.id, "@here heads up")

    assert note.mentions == []
    assert note.team_mentions == []
  end

  test "here_mention/1 is nil for nil team_mentions" do
    assert Messages.here_mention(%Messages.Message{team_mentions: nil}) == nil
    assert Messages.here_mention(%Messages.Message{team_mentions: []}) == nil
  end

  test "an agent's @here doesn't mention the user", ctx do
    {:ok, message} = Messages.post_agent_message(ctx.channel.id, ctx.zed.id, "@here look")

    refute message.mentions_user
  end

  describe "commands" do
    test "/i @agent note @here invites first, then wakes everyone once", ctx do
      newbie = agent_fixture(%{name: "new-" <> unique_suffix()})

      {:ok, message} = Runtime.post_user_message(ctx.channel.id, "/i @#{newbie.name} hi @here")

      here = Messages.here_mention(message)
      assert newbie.id in here["reach"]
      refute newbie.id in here["agent_ids"]
      assert Enum.count(message.mentions, &(&1 == newbie.id)) == 1
    end

    test "/handoff and /delegate bodies never resolve @here", ctx do
      {:ok, _} =
        Runtime.post_user_message(ctx.channel.id, "/handoff @#{ctx.zed.name} over to you @here")

      {:ok, _} =
        Runtime.post_user_message(ctx.channel.id, "/delegate @#{ctx.amy.name} fix it @here")

      here_messages =
        ctx.channel.id
        |> Messages.list(limit: 50)
        |> Enum.filter(&Messages.here_mention/1)

      assert here_messages == []
    end

    test "@here is never a command target", ctx do
      for command <- ["/delegate @here do it", "/handoff @here take it", "/i @here"] do
        assert {:error, reason} = Runtime.post_user_message(ctx.channel.id, command)
        assert reason =~ "@here", command
      end
    end
  end
end
