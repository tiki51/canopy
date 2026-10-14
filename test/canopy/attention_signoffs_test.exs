defmodule Canopy.AttentionSignoffsTest do
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.{Attention, Signoffs}
  alias Canopy.Playbooks.Runs

  setup :set_mox_global

  setup do
    ctx = scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    ctx
  end

  test "a freestanding card and a held run each count once", ctx do
    {:ok, card} =
      Signoffs.request(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.agent.id,
        title: "Header",
        question: "OK?"
      })

    assert Attention.summary()[ctx.channel.id] == %{
             questions: 0,
             permissions: 0,
             approvals: 1,
             playbook: false
           }

    assert [event] = Attention.pending_card_events(DateTime.add(DateTime.utc_now(), -60))
    assert event.event_type == "signoff_requested"
    assert event.ref_id == card.id

    other = channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: ctx.agent.id})
    playbook = playbook_fixture("gate", [{"sign", "Sign", "coordinator", "approval: user"}])

    {:ok, run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: other,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    {:ok, _run, :awaiting_approval} = Runs.advance(run, {:agent, ctx.agent.id}, result: "r")

    assert Attention.summary()[other.id] == %{
             questions: 0,
             permissions: 0,
             approvals: 1,
             playbook: true
           }

    {:ok, _} = Signoffs.accept(card, nil, nil)
    assert Attention.summary()[ctx.channel.id] == nil
  end
end
