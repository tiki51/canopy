defmodule Canopy.SignoffsEdgesTest do
  @moduledoc "Edge cases for sign-off cards beyond the build's own tests (test plan §1–§2)."
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.{Messages, Repo, Signoffs, Timeline}
  alias Canopy.Playbooks.{Run, Runs}
  alias Canopy.Signoffs.SignoffRequest

  setup :set_mox_global

  setup do
    other = agent_fixture(%{name: "other" <> unique_suffix()})
    ctx = scenario(members: [other])
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    Timeline.subscribe(ctx.channel.id)

    playbook =
      playbook_fixture("ship-it", [
        {"plan", "Plan", "coordinator"},
        {"design", "Design approval", "coordinator", "approval: user"},
        {"build", "Build", "coordinator"}
      ])

    Map.merge(ctx, %{other: other, playbook: playbook})
  end

  defp ask!(ctx, attrs \\ %{}) do
    {:ok, signoff} =
      Signoffs.request(
        Map.merge(
          %{
            channel_id: ctx.channel.id,
            agent_id: ctx.agent.id,
            title: "Header",
            question: "Done?"
          },
          attrs
        )
      )

    signoff
  end

  defp hold!(ctx) do
    {:ok, run, false} =
      Runs.start(%{
        playbook: ctx.playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "A new header"
      })

    {:ok, run, _} = Runs.advance(run, {:agent, ctx.agent.id}, result: "planned")
    {:ok, run, :awaiting_approval} = Runs.advance(run, {:agent, ctx.agent.id}, result: "done")
    drain_prompts()
    {run, Signoffs.pending_for_run(run.id)}
  end

  defp drain_prompts do
    receive do
      {:prompted, _, _} -> drain_prompts()
    after
      200 -> :ok
    end
  end

  defp prompts(acc \\ []) do
    receive do
      {:prompted, sid, body} -> prompts([{sid, prompt_text(body)} | acc])
    after
      800 -> Enum.reverse(acc)
    end
  end

  defp user_messages(channel_id),
    do:
      channel_id |> Messages.list() |> Enum.filter(&(is_nil(&1.agent_id) and &1.kind != "system"))

  describe "request/1 boundaries" do
    test "title 80 and question 300 are fine; 81 and 301 are not", ctx do
      assert {:ok, _} =
               Signoffs.request(%{
                 channel_id: ctx.channel.id,
                 agent_id: ctx.agent.id,
                 title: String.duplicate("t", 80),
                 question: String.duplicate("q", 300)
               })

      for {title, question} <- [
            {String.duplicate("t", 81), "q"},
            {"t", String.duplicate("q", 301)},
            {"two\nlines", "q"}
          ] do
        assert {:error, _} =
                 Signoffs.request(%{
                   channel_id: ctx.channel.id,
                   agent_id: ctx.agent.id,
                   title: title,
                   question: question
                 })
      end
    end

    test "option label over 80 and description over 300 are refused", ctx do
      base = %{channel_id: ctx.channel.id, agent_id: ctx.agent.id, title: "T", question: "Q"}

      assert {:error, _} =
               Signoffs.request(
                 Map.put(base, :options, [%{label: String.duplicate("l", 81)}, %{label: "B"}])
               )

      assert {:error, _} =
               Signoffs.request(
                 Map.put(base, :options, [
                   %{label: "A", description: String.duplicate("d", 301)},
                   %{label: "B"}
                 ])
               )
    end
  end

  describe "freestanding answers" do
    test "a 2000-character note is kept whole", ctx do
      note = String.duplicate("n", 2_000)
      assert {:ok, %{note: ^note}} = Signoffs.accept(ask!(ctx), nil, note)
    end

    test "an unknown id is refused without a crash" do
      assert {:error, "already answered"} = Signoffs.accept("so_nope", nil, nil)
      assert {:error, "already answered"} = Signoffs.reject("so_nope", nil)
    end

    test "accept and reject racing: one wins and the message matches it", ctx do
      for _ <- 1..10 do
        signoff = ask!(ctx)

        results =
          [
            fn -> Signoffs.accept(signoff.id, nil, nil) end,
            fn -> Signoffs.reject(signoff.id, nil) end
          ]
          |> Enum.map(&Task.async/1)
          |> Enum.map(&Task.await(&1, 5_000))

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        status = Repo.get!(SignoffRequest, signoff.id).status

        bodies =
          ctx.channel.id
          |> user_messages()
          |> Enum.filter(&(&1.id == Repo.get!(SignoffRequest, signoff.id).message_id))
          |> Enum.map(& &1.body)

        assert [body] = bodies
        assert body =~ if(status == "accepted", do: "Accepted", else: "Rejected")
      end
    end
  end

  describe "run-linked answers" do
    test "two presses on a run card at once release the step once and wake once", ctx do
      {run, card} = hold!(ctx)

      results =
        [
          fn -> Signoffs.accept(card.id, nil, nil) end,
          fn -> Signoffs.accept(card.id, nil, "b") end
        ]
        |> Enum.map(&Task.async/1)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:error, r} -> r in ["already answered", "the run changed meanwhile, try again"]
             end)

      assert length(prompts()) == 1
      step = Runs.get!(run.id).steps |> Enum.find(&(&1.step_id == "design"))
      assert step.status == "done"
    end

    test "a run with no coordinator releases on accept and wakes nobody", ctx do
      {run, card} = hold!(ctx)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [coordinator_agent_id: nil])

      assert {:ok, %{status: "accepted"}} = Signoffs.accept(card.id, nil, "fine")
      assert prompts() == []
      assert Runs.get!(run.id).status != "awaiting_approval"
    end

    test "deleting the run deletes its cards", ctx do
      {run, card} = hold!(ctx)
      Repo.delete!(Repo.get!(Run, run.id))
      assert Signoffs.get(card.id) == nil
      assert Signoffs.pending_for_channel(ctx.channel.id) == []
    end
  end
end
