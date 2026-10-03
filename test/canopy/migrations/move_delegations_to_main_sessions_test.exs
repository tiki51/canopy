defmodule Canopy.Migrations.MoveDelegationsToMainSessionsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Canopy.{Delegations, Repo, Timeline}

  @migration Canopy.Repo.Migrations.MoveDelegationsToMainSessions
  @path "priv/repo/migrations/20261003075423_move_delegations_to_main_sessions.exs"

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)

    delegate = agent_fixture()
    ctx = scenario(members: [delegate])
    delegate_root = session_fixture(%{channel: ctx.channel, agent_id: delegate.id})
    Map.merge(ctx, %{delegate: delegate, delegate_root: delegate_root})
  end

  # The migration file is loaded at run time, so it is called dynamically.
  defp migrate, do: apply(@migration, :move, [Repo, DateTime.utc_now()])

  # An agent's delegation as it ran before: started in a child session of the
  # delegate, whose last turn began `hours` ago.
  defp child_delegation(ctx, description, hours) do
    {:ok, delegation} =
      Delegations.create(%{
        channel_id: ctx.channel.id,
        from_agent_id: ctx.agent.id,
        to_agent_id: ctx.delegate.id,
        description: description
      })

    child =
      session_fixture(%{
        channel: ctx.channel,
        agent_id: ctx.delegate.id,
        parent_session_id: ctx.session.id
      })

    {:ok, delegation} = Delegations.start(delegation, child.id)

    {:ok, started} =
      Timeline.record(%{
        channel_id: ctx.channel.id,
        agent_id: ctx.delegate.id,
        event_type: "agent_started",
        ref_id: child.id
      })

    at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    Repo.update_all(from(e in Timeline.Event, where: e.id == ^started.id), set: [inserted_at: at])

    Repo.update_all(from(d in Delegations.Delegation, where: d.id == ^delegation.id),
      set: [inserted_at: at]
    )

    {delegation, child}
  end

  test "stale delegations are cancelled with a note; live ones move to the delegate's main session",
       ctx do
    {stale, _} = child_delegation(ctx, "abandoned", 30)
    {live, child} = child_delegation(ctx, "still going", 2)
    {finished, _} = child_delegation(ctx, "long done", 48)
    {:ok, _} = Delegations.complete(finished, "done")

    # a fresh one that has not started its session yet
    {:ok, unstarted} =
      Delegations.create(%{
        channel_id: ctx.channel.id,
        from_agent_id: ctx.agent.id,
        to_agent_id: ctx.delegate.id,
        description: "not started"
      })

    migrate()

    assert %{status: "cancelled", completed_at: %DateTime{}} = Delegations.get!(stale.id)
    assert %{status: "completed", result: "done"} = Delegations.get!(finished.id)

    assert %{status: "working", child_session_id: root_id} = Delegations.get!(live.id)
    assert root_id == ctx.delegate_root.id
    refute root_id == child.id

    assert %{status: "requested", child_session_id: ^root_id} = Delegations.get!(unstarted.id)

    assert [note] = Timeline.list(ctx.channel.id, types: ["delegation_cancelled"])
    stale_id = stale.id

    assert %{
             "note" =>
               "Cancelled 1 stale delegation while moving delegated work into agents' main sessions.",
             "delegation_ids" => [^stale_id]
           } = note.payload

    # running it again changes nothing
    migrate()
    assert [_] = Timeline.list(ctx.channel.id, types: ["delegation_cancelled"])
    assert %{status: "working", child_session_id: ^root_id} = Delegations.get!(live.id)
  end

  test "a delegate without a main session yet is left pointing at nothing" do
    other = agent_fixture()
    ctx = Map.put(scenario(members: [other]), :delegate, other)
    {live, _} = child_delegation(ctx, "still going", 1)

    migrate()

    assert %{status: "working", child_session_id: nil} = Delegations.get!(live.id)
  end
end
