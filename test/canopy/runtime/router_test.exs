defmodule Canopy.Runtime.RouterTest do
  use ExUnit.Case, async: true

  alias Canopy.Runtime.Router
  alias Canopy.Timeline.Event

  @backend "agt_backend"
  @reviewer "agt_reviewer"
  @outsider "agt_outsider"

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        channel: %{name: "payments"},
        members: [@backend, @reviewer],
        owner_agent_id: @backend,
        user_name: "Steven",
        lookup: fn
          @backend -> %{name: "backend"}
          @reviewer -> %{name: "reviewer"}
          _ -> nil
        end,
        thread_root: fn _ -> nil end
      },
      overrides
    )
  end

  # The thread's replies as `[{message_id, agent_id}]`, oldest first; the
  # lookup honours the options the channel server's one does
  # (`Canopy.Messages.thread_last_agent/2`).
  defp replies(list) do
    fn "msg_root", opts ->
      list
      |> Enum.filter(fn {id, agent_id} ->
        agent_id != opts[:except] and (is_nil(opts[:before]) or id < opts[:before]) and
          (is_nil(opts[:among]) or agent_id in opts[:among])
      end)
      |> List.last()
      |> then(&(&1 && elem(&1, 1)))
    end
  end

  defp message_event(msg) do
    %Event{
      event_type: "message",
      message:
        Map.merge(
          %{
            id: "msg_1",
            agent_id: nil,
            user: %{display_name: "Steven"},
            mentions: [],
            thread_id: nil,
            kind: "post"
          },
          msg
        )
    }
  end

  test "a user message with no mentions wakes the owner" do
    assert [{{:root, @backend}, text}] = Router.wakeups(message_event(%{}), ctx())
    assert text =~ "#payments"
    assert text =~ "from Steven"
    assert text =~ "Message ID: msg_1"
    refute text =~ "thread"
  end

  test "a user's unaddressed thread reply wakes the thread's author, not the owner" do
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @reviewer} end})
    event = message_event(%{thread_id: "msg_root", kind: "thread_reply"})

    assert [{{:root, @reviewer}, %{text: text, channel_text: _}}] = Router.wakeups(event, ctx)
    assert text =~ "thread"
  end

  test "a user's thread reply still honours mentions over the thread's author" do
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @reviewer} end})

    event =
      message_event(%{thread_id: "msg_root", kind: "thread_reply", mentions: [@backend]})

    assert [{{:root, @backend}, _}] = Router.wakeups(event, ctx)
  end

  test "a user's thread reply falls back to the owner when no agent is in the thread" do
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: nil} end})
    event = message_event(%{thread_id: "msg_root", kind: "thread_reply"})

    assert [{{:root, @backend}, _}] = Router.wakeups(event, ctx)
  end

  test "in a thread the user started, the user's reply wakes the last agent that replied" do
    ctx =
      ctx(%{
        thread_root: fn "msg_root" -> %{agent_id: nil, body: "why is checkout slow?"} end,
        thread_last_agent: replies([{"msg_0", @reviewer}])
      })

    event = message_event(%{thread_id: "msg_root", kind: "thread_reply"})

    assert [{{:root, @reviewer}, %{text: text, channel_text: channel_text}}] =
             Router.wakeups(event, ctx)

    assert text =~ "Thread: msg_root (started by Steven: \"why is checkout slow?\")"
    assert text =~ "canopy_messages_read thread=msg_root"
    assert text =~ "canopy_thread_reply"
    refute text =~ "post your findings with canopy_message_send"

    # the same prompt without the thread's instructions, for a merged channel turn
    assert channel_text =~ "Message ID: msg_1"
    assert channel_text =~ "post your findings with canopy_message_send"
    refute channel_text =~ "Thread: msg_root"
    refute channel_text =~ "canopy_thread_reply"
  end

  test "the last agent in the thread wins over the root's author; one who left does not count" do
    root = fn "msg_root" -> %{agent_id: @backend} end
    event = message_event(%{thread_id: "msg_root", kind: "thread_reply"})

    ctx = ctx(%{thread_root: root, thread_last_agent: replies([{"msg_0", @reviewer}])})
    assert [{{:root, @reviewer}, _}] = Router.wakeups(event, ctx)

    # an agent no longer in the channel is skipped: the member before it wakes
    ctx =
      ctx(%{
        thread_root: root,
        thread_last_agent: replies([{"msg_0", @reviewer}, {"msg_0b", @outsider}])
      })

    assert [{{:root, @reviewer}, _}] = Router.wakeups(event, ctx)

    ctx = ctx(%{thread_root: root, thread_last_agent: replies([{"msg_0", @outsider}])})
    assert [{{:root, @backend}, _}] = Router.wakeups(event, ctx)
  end

  test "only replies older than the routed message count as the last one" do
    # @reviewer replied after the user's reply (msg_1) was posted, before it was routed
    ctx =
      ctx(%{
        thread_root: fn "msg_root" -> %{agent_id: nil} end,
        thread_last_agent: replies([{"msg_0", @backend}, {"msg_2", @reviewer}])
      })

    event = message_event(%{id: "msg_1", thread_id: "msg_root", kind: "thread_reply"})
    assert [{{:root, @backend}, _}] = Router.wakeups(event, ctx)
  end

  test "in a DM thread the user's reply goes to the agent in the thread, not to everyone" do
    dm =
      ctx(%{
        channel: %{name: "dm-backend-reviewer", kind: "dm"},
        thread_root: fn "msg_root" -> %{agent_id: @reviewer} end
      })

    event = message_event(%{thread_id: "msg_root", kind: "thread_reply"})
    assert [{{:root, @reviewer}, _}] = Router.wakeups(event, dm)
  end

  test "in a DM an unaddressed user message wakes every agent, agent posts still need mentions" do
    dm = ctx(%{channel: %{name: "dm-backend-reviewer", kind: "dm"}})

    assert [{{:root, @backend}, _}, {{:root, @reviewer}, _}] =
             Router.wakeups(message_event(%{}), dm)

    assert [{{:root, @reviewer}, _}] = Router.wakeups(message_event(%{mentions: [@reviewer]}), dm)
    assert [] = Router.wakeups(message_event(%{agent_id: @backend}), dm)
  end

  test "mentions win over the owner and exclude non-members" do
    ev = message_event(%{mentions: [@reviewer, @outsider]})
    assert [{{:root, @reviewer}, _}] = Router.wakeups(ev, ctx())
  end

  test "an agent never wakes itself, and the owner's unaddressed posts wake nobody" do
    ev = message_event(%{agent_id: @backend, mentions: [@backend]})
    assert [] = Router.wakeups(ev, ctx())
  end

  test "an automatic reply wakes only who it mentions, never the owner or thread author" do
    reply = message_event(%{agent_id: @reviewer, kind: "reply"})
    assert [] = Router.wakeups(reply, ctx())

    threaded = message_event(%{agent_id: @reviewer, kind: "reply", thread_id: "msg_root"})
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @backend} end})
    assert [] = Router.wakeups(threaded, ctx)

    mentioning = message_event(%{agent_id: @reviewer, kind: "reply", mentions: [@backend]})
    assert [{{:root, @backend}, _}] = Router.wakeups(mentioning, ctx())
  end

  test "another agent's unaddressed post wakes the owner, once" do
    ev = message_event(%{agent_id: @reviewer})
    assert [{{:root, @backend}, text}] = Router.wakeups(ev, ctx())
    assert text =~ "from @reviewer"
    assert text =~ "Members of #payments: @backend, @reviewer"
    assert text =~ "wakes only the agents you @mention, plus the channel owner"

    # no owner, or an owner who left the channel: back to nobody
    assert [] = Router.wakeups(ev, ctx(%{owner_agent_id: nil}))
    assert [] = Router.wakeups(ev, ctx(%{owner_agent_id: @outsider}))
  end

  test "an agent's thread reply wakes the thread root author" do
    ev = message_event(%{agent_id: @reviewer, thread_id: "msg_root", kind: "thread_reply"})
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @backend} end})
    assert [{{:root, @backend}, %{text: text, channel_text: _}}] = Router.wakeups(ev, ctx)
    assert text =~ "from @reviewer"
    assert text =~ "Thread: msg_root"
  end

  test "an agent's unaddressed thread reply never wakes the owner" do
    # @reviewer replies in a thread the user started, alone in it: nobody wakes
    ev = message_event(%{agent_id: @reviewer, thread_id: "msg_root", kind: "thread_reply"})
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: nil} end})
    assert [] = Router.wakeups(ev, ctx)

    # a root author who left the channel is not woken either
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @outsider} end})
    assert [] = Router.wakeups(ev, ctx)

    # the owner replies in @reviewer's thread: @reviewer wakes
    ev = message_event(%{agent_id: @backend, thread_id: "msg_root", kind: "thread_reply"})
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @reviewer} end})
    assert [{{:root, @reviewer}, _}] = Router.wakeups(ev, ctx)
  end

  test "the root's author replying in its own thread wakes the last other agent in it" do
    ev = message_event(%{agent_id: @reviewer, thread_id: "msg_root", kind: "thread_reply"})

    ctx =
      ctx(%{
        thread_root: fn "msg_root" -> %{agent_id: @reviewer} end,
        thread_last_agent: replies([{"msg_0", @backend}, {"msg_0b", @reviewer}])
      })

    assert [{{:root, @backend}, _}] = Router.wakeups(ev, ctx)

    alone = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @reviewer} end})
    assert [] = Router.wakeups(ev, alone)
  end

  test "an agent's reply in a thread the user started wakes the agent that replied before it" do
    # the user started the thread; @backend answered, then @reviewer chimes in
    ctx =
      ctx(%{
        thread_root: fn "msg_root" -> %{agent_id: nil} end,
        thread_last_agent: replies([{"msg_0", @backend}])
      })

    ev =
      message_event(%{
        id: "msg_1",
        agent_id: @reviewer,
        thread_id: "msg_root",
        kind: "thread_reply"
      })

    assert [{{:root, @backend}, %{text: text, channel_text: _}}] = Router.wakeups(ev, ctx)
    assert text =~ "Unaddressed, it wakes the agent that replied last in the thread before you"
    refute text =~ "plus the channel owner"
  end

  test "mentions still win in a thread, for agents and the user alike" do
    ctx =
      ctx(%{
        thread_root: fn "msg_root" -> %{agent_id: @reviewer} end,
        thread_last_agent: replies([{"msg_0", @reviewer}])
      })

    ev =
      message_event(%{
        agent_id: @reviewer,
        thread_id: "msg_root",
        kind: "thread_reply",
        mentions: [@backend]
      })

    assert [{{:root, @backend}, _}] = Router.wakeups(ev, ctx)

    ev = message_event(%{thread_id: "msg_root", kind: "thread_reply", mentions: [@backend]})
    assert [{{:root, @backend}, _}] = Router.wakeups(ev, ctx)
  end

  test "a user message with no owner wakes nobody" do
    assert [] = Router.wakeups(message_event(%{}), ctx(%{owner_agent_id: nil}))
  end

  test "delegation_created wakes the delegate's own session, whoever delegated" do
    ev = %Event{
      event_type: "delegation_created",
      ref_id: "dl_1",
      payload: %{
        "from_agent_id" => @backend,
        "to_agent_id" => @reviewer,
        "description" => "trace enqueue paths"
      }
    }

    assert [{{:root, @reviewer}, text}] = Router.wakeups(ev, ctx())
    assert text =~ "@backend delegated"
    assert text =~ "Delegation ID: dl_1"
    assert text =~ "trace enqueue paths"
    assert text =~ ~s(delegation "dl_1")

    from_user = put_in(ev.payload["from_agent_id"], nil)
    assert [{{:root, @reviewer}, text}] = Router.wakeups(from_user, ctx())
    assert text =~ "Steven delegated"
  end

  test "a message about a delegation wakes the delegate's own session" do
    event =
      message_event(%{
        agent_id: @backend,
        mentions: [@reviewer],
        body: "@reviewer re dl_01M3P41N, also check the retries"
      })

    assert [{{:root, @reviewer}, _}] = Router.wakeups(event, ctx())
  end

  test "delegation_completed wakes the delegator with the result" do
    ev = %Event{
      event_type: "delegation_completed",
      ref_id: "dl_1",
      payload: %{
        "from_agent_id" => @backend,
        "to_agent_id" => @reviewer,
        "result" => "three paths"
      }
    }

    assert [{{:root, @backend}, text}] = Router.wakeups(ev, ctx())
    assert text =~ "completed by @reviewer"
    assert text =~ "three paths"
  end

  test "handoff events wake the right side" do
    req = %Event{
      event_type: "handoff_requested",
      ref_id: "ho_1",
      payload: %{"from_agent_id" => @backend, "to_agent_id" => @reviewer}
    }

    assert [{{:root, @reviewer}, text}] = Router.wakeups(req, ctx())
    assert text =~ "Handoff ID: ho_1"
    assert text =~ "canopy_handoff_accept"

    acc = %Event{
      event_type: "handoff_accepted",
      ref_id: "ho_1",
      payload: %{"from_agent_id" => @backend, "to_agent_id" => @reviewer}
    }

    assert [{{:root, @backend}, text}] = Router.wakeups(acc, ctx())
    assert text =~ "@reviewer accepted"

    rej = %Event{
      event_type: "handoff_rejected",
      ref_id: "ho_1",
      payload: %{
        "from_agent_id" => @backend,
        "to_agent_id" => @reviewer,
        "reason" => "not my area"
      }
    }

    assert [{{:root, @backend}, text}] = Router.wakeups(rej, ctx())
    assert text =~ "not my area"
  end

  test "other events wake nobody" do
    assert [] = Router.wakeups(%Event{event_type: "agent_started"}, ctx())
    assert [] = Router.wakeups(%Event{event_type: "permission_requested"}, ctx())
  end

  test "a message with documents wakes with the attachments plan" do
    small = %Canopy.Documents.Document{
      id: "doc_a",
      filename: "a.png",
      kind: "image",
      byte_size: 10
    }

    big = %Canopy.Documents.Document{id: "doc_b", filename: "b.pdf", kind: "pdf", byte_size: 10}

    [{{:root, @backend}, wake}] =
      Router.wakeups(message_event(%{documents: [small, big]}), ctx())

    assert %{text: text, attachments: [{^small, :part}, {^big, :path}]} = wake
    assert text =~ "doc_a a.png (image, 10 B) — attached to this prompt as an image"

    [{{:root, @backend}, plain}] = Router.wakeups(message_event(%{}), ctx())
    assert is_binary(plain)
  end

  describe "team mentions" do
    test "wake only members in the channel, never the sender, and share one charge" do
      team = %{
        "team_id" => "tm_crew",
        "name" => "crew",
        "agent_ids" => [@backend, @reviewer, @outsider]
      }

      ev =
        message_event(%{
          id: "msg_t",
          agent_id: @backend,
          mentions: [@backend, @reviewer, @outsider],
          team_mentions: [team]
        })

      assert [{{:root, @reviewer}, %{text: _, charge: {"msg_t", "tm_crew"}}}] =
               Router.wakeups(ev, ctx())
    end

    test "an agent also named directly carries no team charge" do
      team = %{"team_id" => "tm_crew", "name" => "crew", "agent_ids" => [@reviewer]}

      ev =
        message_event(%{id: "msg_t", mentions: [@backend, @reviewer], team_mentions: [team]})

      assert [{{:root, @backend}, backend_wake}, {{:root, @reviewer}, reviewer_wake}] =
               Router.wakeups(ev, ctx())

      assert is_binary(backend_wake)
      assert %{charge: {"msg_t", "tm_crew"}} = reviewer_wake
    end

    test "the wake names the teams the channel holds whole" do
      [{_, text}] = Router.wakeups(message_event(%{}), ctx(%{teams: ["crew"]}))
      assert text =~ "Teams here: @crew."
    end
  end
end
