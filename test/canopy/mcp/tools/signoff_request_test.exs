defmodule Canopy.MCP.Tools.SignoffRequestTest do
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.Fixtures
  import Canopy.MCPHelpers
  import Canopy.PlaybookHelpers

  alias Canopy.MCP.Server
  alias Canopy.MCP.Tools.{PlaybookAdvance, PlaybookStart, SignoffRequest}
  alias Canopy.Playbooks.Runs
  alias Canopy.Signoffs

  setup :set_mox_global

  setup do
    dev = agent_fixture(name: "dev-" <> unique_suffix())
    ctx = scenario(members: [dev])
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    dev_session = session_fixture(%{channel: ctx.channel, agent_id: dev.id})

    playbook_fixture(
      "ship-it",
      [
        {"plan", "Plan", "coordinator"},
        {"design", "Design", "dev", "approval: user"},
        {"build", "Build", "dev"}
      ],
      "roles:\n  dev: #{dev.name}\n"
    )

    Map.merge(ctx, %{dev: dev, dev_session: dev_session})
  end

  test "the tool is registered" do
    assert "signoff_request" in Server.tool_names()
  end

  test "a card goes up in the caller's channel, with options and attachments", ctx do
    {:ok, doc} =
      Canopy.Documents.create(%{
        filename: "mock.md",
        source: {:binary, "x"},
        agent_id: ctx.agent.id
      })

    assert {:ok, text} =
             call(
               SignoffRequest,
               %{
                 title: "Header design",
                 question: "Which header?",
                 summary: "Three mocks.",
                 options: [
                   %{label: "Totals on top", description: "Sum first"},
                   %{label: "Totals below", recommended: true}
                 ],
                 attachments: doc.id
               },
               ctx
             )

    [card] = Signoffs.pending_for_channel(ctx.channel.id)
    assert text =~ "Sign-off card [#{card.id}] is up in ##{ctx.channel.name}. End your turn"
    assert card.agent_id == ctx.agent.id
    assert card.summary == "Three mocks."

    assert card.options == [
             %{"label" => "Totals on top", "description" => "Sum first", "recommended" => false},
             %{"label" => "Totals below", "description" => nil, "recommended" => true}
           ]

    assert card.document_ids == [doc.id]
  end

  test "a single option is refused", ctx do
    assert {:error, reason} =
             call(SignoffRequest, %{title: "T", question: "Q?", options: [%{label: "one"}]}, ctx)

    assert reason =~ "give 2–6 options, or none for Accept / Reject"
    assert Signoffs.pending_for_channel(ctx.channel.id) == []
  end

  test "the coordinator on an approval step is sent to playbook_advance", ctx do
    {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)
    {:ok, _} = call(PlaybookAdvance, %{result: "planned"}, ctx)

    assert {:error, reason} = call(SignoffRequest, %{title: "Design", question: "OK?"}, ctx)
    assert reason =~ "step design is a sign-off step: hold it with canopy_playbook_advance"

    # a step owner gets its card, told that it does not release the step
    assert {:ok, text} =
             call(SignoffRequest, %{title: "Palette", question: "Which?"}, ctx.dev_session)

    assert text =~ "This card does not release step design"
  end

  test "while a step is held, nobody puts up another card", ctx do
    {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)
    {:ok, _} = call(PlaybookAdvance, %{result: "planned"}, ctx)
    {:ok, text} = call(PlaybookAdvance, %{result: "designed"}, ctx)
    assert text =~ "is waiting for the user's sign-off"

    for who <- [ctx, ctx.dev_session] do
      assert {:error, reason} = call(SignoffRequest, %{title: "Again", question: "OK?"}, who)
      assert reason =~ "already signing off step design of ship-it"
    end

    assert length(Signoffs.pending_for_channel(ctx.channel.id)) == 1
  end

  describe "playbook_advance" do
    test "holding a step takes the card's question, options and attachments", ctx do
      {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)
      {:ok, _} = call(PlaybookAdvance, %{result: "planned"}, ctx)

      {:ok, doc} =
        Canopy.Documents.create(%{
          filename: "a.md",
          source: {:binary, "a"},
          agent_id: ctx.agent.id
        })

      assert {:ok, text} =
               call(
                 PlaybookAdvance,
                 %{
                   result: "Three directions.",
                   question: "Which direction?",
                   options: [%{label: "A"}, %{label: "B", recommended: true}],
                   attachments: doc.id
                 },
                 ctx
               )

      run = Runs.active_for_channel(ctx.channel.id)
      card = Signoffs.pending_for_run(run.id)

      assert text =~ "\"Design\" is waiting for the user's sign-off: the card [#{card.id}]"
      assert text =~ "Post nothing more about it and end your turn"
      assert card.question == "Which direction?"
      assert card.summary == "Three directions."
      assert Enum.map(card.options, & &1["label"]) == ["A", "B"]
      assert card.document_ids == [doc.id]
    end

    test "card fields on an advance that does not hold are ignored, and said so", ctx do
      {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)

      assert {:ok, text} =
               call(PlaybookAdvance, %{result: "planned", question: "Is it?"}, ctx)

      assert text =~ "moved on"
      assert text =~ "question/options/attachments were ignored"
      assert Signoffs.pending_for_channel(ctx.channel.id) == []
    end

    test "an attachment path is shared only by an advance that holds", ctx do
      File.write!(Path.join(ctx.repository.path, "mock.md"), "# mock")
      {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)
      before = Repo.aggregate(Canopy.Documents.Document, :count)

      {:ok, text} = call(PlaybookAdvance, %{result: "planned", attachments: "mock.md"}, ctx)
      assert text =~ "question/options/attachments were ignored"
      assert Repo.aggregate(Canopy.Documents.Document, :count) == before

      {:ok, _} = call(PlaybookAdvance, %{result: "designed", attachments: "mock.md"}, ctx)
      card = Signoffs.pending_for_run(Runs.active_for_channel(ctx.channel.id).id)
      assert [%{filename: "mock.md"}] = card.documents
      assert Repo.aggregate(Canopy.Documents.Document, :count) == before + 1
    end

    test "invalid options fail the advance; the run is unchanged", ctx do
      {:ok, _} = call(PlaybookStart, %{name: "ship-it", brief: "v2"}, ctx)
      {:ok, _} = call(PlaybookAdvance, %{result: "planned"}, ctx)

      assert {:error, reason} =
               call(PlaybookAdvance, %{result: "x", options: [%{label: "only"}]}, ctx)

      assert reason =~ "give 2–6 options"
      assert Runs.active_for_channel(ctx.channel.id).status == "active"
    end
  end
end
