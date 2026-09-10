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
    ev = message_event(%{agent_id: @reviewer, thread_id: "msg_root"})
    ctx = ctx(%{thread_root: fn "msg_root" -> %{agent_id: @backend} end})
    assert [{{:root, @backend}, text}] = Router.wakeups(ev, ctx)
    assert text =~ "from @reviewer"
    assert text =~ "thread"
  end

  test "a user message with no owner wakes nobody" do
    assert [] = Router.wakeups(message_event(%{}), ctx(%{owner_agent_id: nil}))
  end

  test "delegation_created wakes the delegate in a child session" do
    ev = %Event{
      event_type: "delegation_created",
      ref_id: "dl_1",
      payload: %{
        "from_agent_id" => @backend,
        "to_agent_id" => @reviewer,
        "description" => "trace enqueue paths"
      }
    }

    assert [{{:child, "dl_1"}, text}] = Router.wakeups(ev, ctx())
    assert text =~ "@backend delegated"
    assert text =~ "Delegation ID: dl_1"
    assert text =~ "trace enqueue paths"
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
end
