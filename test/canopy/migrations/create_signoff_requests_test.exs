defmodule Canopy.Migrations.CreateSignoffRequestsTest do
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.Playbooks.{Run, Runs, Step}
  alias Canopy.Signoffs
  alias Canopy.Signoffs.SignoffRequest

  @migration Canopy.Repo.Migrations.CreateSignoffRequests
  @path "priv/repo/migrations/20261014000000_create_signoff_requests.exs"

  setup :set_mox_global

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    ctx = scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    ctx
  end

  # The migration file is loaded at run time, so it is called dynamically.
  defp backfill, do: apply(@migration, :backfill, [Repo])

  # A run held for approval as it was before cards existed: no card.
  defp held_run(ctx, name) do
    playbook = playbook_fixture(name, [{"sign", "Sign it", "coordinator", "approval: user"}])

    channel =
      channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: ctx.agent.id})

    {:ok, run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "b"
      })

    {:ok, run, :awaiting_approval} =
      Runs.advance(run, {:agent, ctx.agent.id}, result: "the result")

    Repo.delete_all(from s in SignoffRequest, where: s.run_id == ^run.id)
    run
  end

  test "every held step gets one pending card; running it again adds none", ctx do
    run = held_run(ctx, "held")
    assert backfill() == 1

    card = Signoffs.pending_for_run(run.id)

    assert %{
             title: "Sign it",
             question: ~s(Is "Sign it" done?),
             summary: "the result",
             step_id: "sign",
             options: [],
             document_ids: []
           } = card

    assert card.agent_id == ctx.agent.id
    assert card.channel_id == run.channel_id
    assert %DateTime{} = card.inserted_at

    assert backfill() == 0

    # the backfilled card releases the run like any other
    assert {:ok, _} = Signoffs.accept(card, nil, nil)
    assert Runs.get!(run.id).status == "completed"
  end

  test "no coordinator, no result, and a long title still backfill", ctx do
    run = held_run(ctx, "odd")
    step = Enum.find(run.steps, &(&1.step_id == "sign"))

    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [coordinator_agent_id: nil])

    Repo.update_all(from(s in Step, where: s.id == ^step.id),
      set: [result: nil, title: String.duplicate("long title ", 12)]
    )

    assert backfill() == 1
    card = Signoffs.pending_for_run(run.id)
    assert card.agent_id == nil
    assert card.summary == nil
    assert String.length(card.title) == 80
    assert String.ends_with?(card.title, "…")
    assert String.length(card.question) <= 300
  end
end
