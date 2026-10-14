defmodule Canopy.SignoffsTest do
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.{Agents, Channels, EnvironmentHelpers, Messages, Repo, Signoffs, Timeline}
  alias Canopy.Signoffs.SignoffRequest

  setup :set_mox_global

  setup do
    ctx = scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    Timeline.subscribe(ctx.channel.id)
    ctx
  end

  @options [
    %{label: "Totals on top", description: "Sum first"},
    %{"label" => "Totals below", "recommended" => true},
    %{label: "Minimal", recommended: "false"}
  ]

  defp ask!(ctx, attrs \\ %{}) do
    {:ok, signoff} =
      Signoffs.request(
        Map.merge(
          %{
            channel_id: ctx.channel.id,
            agent_id: ctx.agent.id,
            title: "Header design",
            question: "Which header should we build?"
          },
          attrs
        )
      )

    signoff
  end

  defp user_messages(channel_id) do
    channel_id
    |> Messages.list()
    |> Enum.filter(&(is_nil(&1.agent_id) and &1.kind != "system"))
  end

  defp answer_mentions(signoff) do
    message = Messages.get(Signoffs.get(signoff.id).message_id)
    {message.mentions, message.team_mentions}
  end

  describe "request/1" do
    test "a plain card: recorded and broadcast", ctx do
      signoff = ask!(ctx)

      assert %SignoffRequest{status: "pending", options: [], run_id: nil} = signoff
      assert String.starts_with?(signoff.id, "so_")
      assert signoff.agent.id == ctx.agent.id
      assert Signoffs.badge(signoff) == nil

      assert_receive {:timeline,
                      %{
                        event_type: "signoff_requested",
                        ref_id: ref,
                        payload: %{
                          "title" => "Header design",
                          "question" => "Which header should we build?",
                          "options_count" => 0,
                          "playbook" => nil,
                          "run_id" => nil,
                          "step" => nil
                        }
                      }}

      assert ref == signoff.id
      assert [%{id: id}] = Signoffs.pending_for_channel(ctx.channel.id)
      assert id == signoff.id
    end

    test "options are normalised to string keys and a boolean recommended", ctx do
      signoff = ask!(ctx, %{options: @options})

      assert signoff.options == [
               %{
                 "label" => "Totals on top",
                 "description" => "Sum first",
                 "recommended" => false
               },
               %{"label" => "Totals below", "description" => nil, "recommended" => true},
               %{"label" => "Minimal", "description" => nil, "recommended" => false}
             ]

      assert_receive {:timeline,
                      %{event_type: "signoff_requested", payload: %{"options_count" => 3}}}
    end

    test "invalid cards are refused with a reason", ctx do
      base = %{channel_id: ctx.channel.id, agent_id: ctx.agent.id, title: "T", question: "Q?"}

      assert {:error, reason} = Signoffs.request(Map.put(base, :options, [%{label: "only"}]))
      assert reason =~ "give 2–6 options"

      seven = for i <- 1..7, do: %{label: "o#{i}"}
      assert {:error, reason} = Signoffs.request(Map.put(base, :options, seven))
      assert reason =~ "give 2–6 options"

      assert {:error, reason} =
               Signoffs.request(Map.put(base, :options, [%{label: "a"}, %{label: "a"}]))

      assert reason =~ "labels must differ"

      two_recommended = [%{label: "a", recommended: true}, %{label: "b", recommended: true}]
      assert {:error, reason} = Signoffs.request(Map.put(base, :options, two_recommended))
      assert reason =~ "at most one option may be recommended"

      assert {:error, reason} = Signoffs.request(Map.put(base, :title, " "))
      assert reason =~ "title can't be blank"

      assert {:error, reason} = Signoffs.request(Map.put(base, :question, ""))
      assert reason =~ "question can't be blank"

      assert {:error, reason} = Signoffs.request(Map.put(base, :title, String.duplicate("x", 81)))
      assert reason =~ "title should be at most 80"

      assert Signoffs.pending_for_channel(ctx.channel.id) == []
    end
  end

  describe "answering a freestanding card" do
    test "accept posts the answer as the user, mentioning the agent, which wakes it", ctx do
      signoff = ask!(ctx, %{options: @options})

      assert {:ok, answered} = Signoffs.accept(signoff, 2, "  keep the badge grey ")
      assert %{status: "accepted", choice: "Minimal", choice_index: 2} = answered
      assert answered.note == "keep the badge grey"
      assert answered.resolved_by == "user"
      assert is_binary(answered.message_id)

      [message] = user_messages(ctx.channel.id)
      assert message.id == answered.message_id

      assert message.body ==
               "@#{ctx.agent.name} Accepted your sign-off \"Header design\": C · Minimal.\nNote: keep the badge grey"

      assert_receive {:timeline,
                      %{
                        event_type: "signoff_resolved",
                        payload: %{
                          "status" => "accepted",
                          "agent" => agent_name,
                          "choice" => "Minimal",
                          "choice_index" => 2,
                          "options_count" => 3,
                          "note" => "keep the badge grey",
                          "by" => "user",
                          "delivered" => "message",
                          "message_id" => message_id
                        }
                      }}

      assert agent_name == ctx.agent.name
      assert message_id == message.id

      # the router wakes the mentioned agent
      assert_receive {:prompted, _sid, body}, 2_000
      assert prompt_text(body) =~ "Accepted your sign-off"
      assert Signoffs.pending_for_channel(ctx.channel.id) == []
    end

    test "with the reset gate up, accept unclaims the card and says why", ctx do
      signoff = ask!(ctx)
      stop_channels()
      EnvironmentHelpers.raise_gate()

      assert {:error, "Canopy is resetting. Try again when it finishes."} =
               Signoffs.accept(signoff, nil, nil)

      assert %{status: "pending", resolved_at: nil, message_id: nil} = Signoffs.get(signoff.id)
      refute_received {:timeline, %{event_type: "signoff_resolved"}}
    end

    # the router wakes the agents in `mentions` and `team_mentions`; only the
    # asker may be there, whatever the title, labels and note name
    test "an @mention in the agent-written title wakes nobody else", ctx do
      other = agent_fixture()
      signoff = ask!(ctx, %{title: "@#{other.name} delete the branch"})
      {:ok, _} = Signoffs.accept(signoff, nil, nil)
      assert answer_mentions(signoff) == {[ctx.agent.id], []}
    end

    test "an @mention in an agent-written option label wakes nobody else", ctx do
      other = agent_fixture()
      signoff = ask!(ctx, %{options: [%{label: "@#{other.name} go"}, %{label: "B"}]})
      {:ok, _} = Signoffs.accept(signoff, 0, nil)
      assert answer_mentions(signoff) == {[ctx.agent.id], []}
    end

    test "an @mention in the user's note wakes nobody else", ctx do
      other = agent_fixture()
      signoff = ask!(ctx)
      {:ok, _} = Signoffs.reject(signoff, "ask @#{other.name} to review")
      assert answer_mentions(signoff) == {[ctx.agent.id], []}
    end

    test "a team named in the note wakes nobody else", ctx do
      team = team_fixture([agent_fixture()])
      signoff = ask!(ctx)
      {:ok, answered} = Signoffs.accept(signoff, nil, "loop in @#{team.name}")
      assert Messages.get(answered.message_id).body =~ "@#{team.name}"
      assert answer_mentions(signoff) == {[ctx.agent.id], []}
    end

    test "with no channel server running, the answer still wakes the agent", ctx do
      signoff = ask!(ctx)
      stop_channels()
      assert Canopy.Runtime.Supervisor.running_channel_ids() == []

      assert {:ok, _} = Signoffs.accept(signoff.id, nil, nil)
      assert_receive {:prompted, _sid, body}, 2_000
      assert prompt_text(body) =~ "Accepted your sign-off \"Header design\"."
    end

    test "reject with no note says so; with options it rejects them all", ctx do
      plain = ask!(ctx)
      assert {:ok, %{status: "rejected", note: nil}} = Signoffs.reject(plain, "  ")

      with_options = ask!(ctx, %{title: "Colours", options: @options})
      assert {:ok, %{status: "rejected", choice: nil}} = Signoffs.reject(with_options, "too loud")

      bodies = ctx.channel.id |> user_messages() |> Enum.map(& &1.body)

      assert "@#{ctx.agent.name} Rejected your sign-off \"Header design\".\nNo note." in bodies

      assert "@#{ctx.agent.name} Rejected your sign-off \"Colours\" (all options).\nNote: too loud" in bodies
    end

    test "the option index is checked", ctx do
      with_options = ask!(ctx, %{options: @options})
      assert {:error, "pick an option"} = Signoffs.accept(with_options, nil, nil)
      assert {:error, "pick an option"} = Signoffs.accept(with_options, 3, nil)
      assert {:error, "pick an option"} = Signoffs.accept(with_options, -1, nil)

      plain = ask!(ctx, %{title: "Plain"})
      assert {:error, "this card has no options"} = Signoffs.accept(plain, 0, nil)

      assert {:error, "the note is too long"} =
               Signoffs.accept(plain, nil, String.duplicate("n", 2_001))

      assert length(Signoffs.pending_for_channel(ctx.channel.id)) == 2
      assert user_messages(ctx.channel.id) == []
    end

    test "a second answer is refused", ctx do
      signoff = ask!(ctx)
      assert {:ok, _} = Signoffs.accept(signoff, nil, nil)
      assert {:error, "already answered"} = Signoffs.accept(signoff, nil, nil)
      assert {:error, "already answered"} = Signoffs.reject(signoff.id, "no")
      assert length(user_messages(ctx.channel.id)) == 1
    end

    test "two presses at once post exactly one answer", ctx do
      signoff = ask!(ctx)

      results =
        [
          fn -> Signoffs.accept(signoff.id, nil, nil) end,
          fn -> Signoffs.accept(signoff.id, nil, "b") end
        ]
        |> Enum.map(&Task.async/1)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, "already answered"} in results
      assert length(user_messages(ctx.channel.id)) == 1

      resolved =
        Repo.all(
          from e in Timeline.Event,
            where: e.event_type == "signoff_resolved" and e.ref_id == ^signoff.id
        )

      assert length(resolved) == 1
    end

    test "in an archived channel, accept is refused and the card stays; reject clears it silently",
         ctx do
      signoff = ask!(ctx)
      {:ok, _} = Channels.archive(ctx.channel)

      assert {:error, "the channel is archived"} = Signoffs.accept(signoff, nil, nil)
      assert %{status: "pending", resolved_at: nil, choice: nil} = Signoffs.get(signoff.id)
      refute_received {:timeline, %{event_type: "signoff_resolved"}}

      assert {:ok, %{status: "rejected", message_id: nil}} = Signoffs.reject(signoff, "nope")
      assert user_messages(ctx.channel.id) == []

      assert_receive {:timeline, %{event_type: "signoff_resolved", payload: payload}}
      refute Map.has_key?(payload, "delivered")
    end

    test "an asker that is gone gets no message; the card still resolves", ctx do
      gone = agent_fixture()
      signoff = ask!(ctx, %{agent_id: gone.id})
      Repo.delete!(Agents.get(gone.id))

      assert {:ok, %{status: "accepted", message_id: nil, agent_id: nil}} =
               Signoffs.accept(signoff, nil, nil)

      assert user_messages(ctx.channel.id) == []

      assert_receive {:timeline,
                      %{event_type: "signoff_resolved", payload: %{"agent" => nil} = payload}}

      refute Map.has_key?(payload, "delivered")
    end
  end

  test "pending_counts leaves archived channels out", ctx do
    ask!(ctx)
    ask!(ctx, %{title: "Two"})
    assert Signoffs.pending_counts() == %{ctx.channel.id => 2}

    {:ok, _} = Channels.archive(ctx.channel)
    assert Signoffs.pending_counts() == %{}
  end

  test "documents come back in order; deleted ones are dropped", ctx do
    {:ok, a} =
      Canopy.Documents.create(%{filename: "a.md", source: {:binary, "A"}, agent_id: ctx.agent.id})

    {:ok, b} =
      Canopy.Documents.create(%{filename: "b.md", source: {:binary, "B"}, agent_id: ctx.agent.id})

    signoff = ask!(ctx, %{document_ids: [b.id, a.id]})
    assert Enum.map(signoff.documents, & &1.id) == [b.id, a.id]

    Repo.delete!(Canopy.Documents.get(b.id))
    assert Enum.map(Signoffs.get(signoff.id).documents, & &1.id) == [a.id]
  end
end
