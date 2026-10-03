defmodule Canopy.AttentionTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Attention, Fixtures, PermissionRequests, QuestionRequests}

  defp question(ctx, channel, id) do
    {:ok, request} =
      QuestionRequests.record(%{
        channel_id: channel.id,
        agent_session_id: ctx.session.id,
        opencode_question_id: id,
        questions: [%{"question" => "Go on?", "options" => [%{"label" => "Yes"}]}],
        status: "pending"
      })

    request
  end

  test "counts the cards waiting on the user per channel, detached ones included" do
    ctx = Fixtures.scenario()
    other = Fixtures.channel_fixture(%{repository_id: ctx.repository.id})
    assert Attention.summary() |> Map.take([ctx.channel.id, other.id]) == %{}

    first = question(ctx, ctx.channel, "que_a_" <> Fixtures.unique_suffix())
    _second = question(ctx, ctx.channel, "que_b_" <> Fixtures.unique_suffix())
    {:ok, _} = QuestionRequests.detach(first)

    {:ok, _} =
      PermissionRequests.record(%{
        channel_id: other.id,
        agent_session_id: ctx.session.id,
        opencode_permission_id: "per_" <> Fixtures.unique_suffix(),
        permission: "edit",
        status: "pending"
      })

    summary = Attention.summary()

    assert summary[ctx.channel.id] == %{
             questions: 2,
             permissions: 0,
             approvals: 0,
             playbook: false
           }

    assert summary[other.id] == %{questions: 0, permissions: 1, approvals: 0, playbook: false}
    assert Attention.total(summary[ctx.channel.id]) == 2

    {:ok, _} = QuestionRequests.resolve(first, :rejected)

    assert Attention.summary()[ctx.channel.id] == %{
             questions: 1,
             permissions: 0,
             approvals: 0,
             playbook: false
           }
  end

  test "detached cards stop badging after a day, and archived channels never badge" do
    ctx = Fixtures.scenario()
    other = Fixtures.channel_fixture(%{repository_id: ctx.repository.id})
    other_session = Fixtures.session_fixture(%{channel: other, agent_id: ctx.agent.id})

    old = question(ctx, ctx.channel, "que_old_" <> Fixtures.unique_suffix())
    {:ok, old} = QuestionRequests.detach(old)

    old
    |> Ecto.Changeset.change(detached_at: DateTime.add(DateTime.utc_now(), -25, :hour))
    |> Canopy.Repo.update!()

    assert Attention.summary()[ctx.channel.id] == nil

    _fresh = question(ctx, ctx.channel, "que_fresh_" <> Fixtures.unique_suffix())

    assert Attention.summary()[ctx.channel.id] == %{
             questions: 1,
             permissions: 0,
             approvals: 0,
             playbook: false
           }

    _archived =
      question(%{ctx | session: other_session}, other, "que_arch_" <> Fixtures.unique_suffix())

    assert Attention.summary()[other.id] == %{
             questions: 1,
             permissions: 0,
             approvals: 0,
             playbook: false
           }

    {:ok, _} = Canopy.Channels.archive(other)
    assert Attention.summary()[other.id] == nil
  end
end
