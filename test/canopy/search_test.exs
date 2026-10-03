defmodule Canopy.SearchTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Canopy.{Channels, Documents, Messages, Search, Timeline}
  alias Canopy.Messages.Message
  alias Canopy.Search.{Backfill, Entry, Query}

  setup do
    scenario()
  end

  defp fts_count, do: Repo.one(from(f in "search_fts", select: count()))

  defp entry_count(source, ref_id),
    do:
      Repo.aggregate(from(e in Entry, where: e.source == ^source and e.ref_id == ^ref_id), :count)

  defp ids(text, opts \\ []),
    do: text |> Search.search(opts) |> Map.fetch!(:results) |> Enum.map(& &1.ref_id)

  defp turn(ctx, payload, attrs \\ %{}) do
    {:ok, event} =
      Timeline.record(
        Map.merge(
          %{
            channel_id: ctx.channel.id,
            agent_id: ctx.agent.id,
            event_type: "agent_turn_completed",
            ref_id: ctx.session.id,
            payload: payload
          },
          attrs
        )
      )

    event
  end

  defp text_document(filename, content, attrs \\ %{}) do
    {:ok, document} =
      attrs
      |> Map.merge(%{filename: filename, source: {:binary, content}})
      |> Map.put_new(:user_id, user_fixture().id)
      |> Documents.create()

    document
  end

  defp backdate(%Message{id: id}, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Repo.update_all(from(m in Message, where: m.id == ^id), set: [inserted_at: at])
  end

  describe "the index" do
    test "a message gets one entry and one text row; editing and deleting follow", ctx do
      before = fts_count()
      {:ok, message} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "pelican sighting")

      assert entry_count("message", message.id) == 1
      assert fts_count() == before + 1
      assert ids("pelican") == [message.id]

      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [body: "heron sighting"]
      )

      assert ids("pelican") == []
      assert ids("heron") == [message.id]
      assert fts_count() == before + 1

      {:ok, _} = Repo.delete(Repo.get!(Message, message.id))
      assert entry_count("message", message.id) == 0
      assert fts_count() == before
    end

    test "deleting a channel removes its entries", ctx do
      {:ok, message} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "ephemeral words")
      turn(ctx, %{"final_text" => "ephemeral turn"})
      assert length(ids("ephemeral")) == 2

      Repo.delete!(Channels.get!(ctx.channel.id))

      assert entry_count("message", message.id) == 0
      assert ids("ephemeral") == []
      assert Repo.aggregate(from(e in Entry, where: e.channel_id == ^ctx.channel.id), :count) == 0
    end

    test "a finished turn is indexed with its files, tool lines, final text and note", ctx do
      event =
        turn(ctx, %{
          "files" => ["src/billing/enqueue_charge.py", "README.md"],
          "final_text" => "Moved the claim before the charge",
          "note" => "nothing left for me",
          "activity" => [
            %{
              "kind" => "tool",
              "label" => "mix test",
              "command" => "mix test test/billing",
              "detail" => nil
            },
            %{"kind" => "tool", "label" => "lib/payments.ex", "category" => "edit"},
            %{"kind" => "tool", "label" => "grep", "detail" => "exit status 2"},
            %{"kind" => "text", "label" => "narration about walruses"},
            %{"kind" => "tool", "label" => "canopy message_send", "category" => "canopy"},
            %{"kind" => "tool", "label" => "mcp__canopy__messages_read", "detail" => "ocelot"}
          ]
        })

      for query <- [
            "enqueue_charge",
            "README.md",
            "claim",
            "nothing left",
            "test/billing",
            "payments",
            "status"
          ] do
        assert ids(query) == [event.id], "expected #{query} to find the turn"
      end

      assert ids("walruses") == []
      assert ids("message_send") == []
      assert ids("ocelot") == []

      [result] = Search.search("enqueue_charge", marks: {"[", "]"}).results
      assert result.source == "turn"
      assert result.record.id == event.id
      assert result.snippet =~ "src/billing/[enqueue_charge].py"
    end

    test "other event types are not indexed", ctx do
      {:ok, _} =
        Timeline.record(%{
          channel_id: ctx.channel.id,
          event_type: "task_updated",
          payload: %{"final_text" => "giraffe"}
        })

      assert ids("giraffe") == []
    end

    test "rewriting a turn's payload, as the costs backfill does, reindexes it", ctx do
      event = turn(ctx, %{"final_text" => "first wording"})
      assert ids("first") == [event.id]

      Repo.update_all(from(e in Timeline.Event, where: e.id == ^event.id),
        set: [payload: %{"final_text" => "second wording", "model" => "x"}]
      )

      assert ids("first") == []
      assert ids("second") == [event.id]
    end

    test "a text document is indexed by name, caption and content, cut at 1 MB", ctx do
      big = "aardvark " <> String.duplicate("x", 1_048_576) <> " zebra"

      doc =
        text_document("retry-audit.md", big, %{
          caption: "the audit",
          origin_channel_id: ctx.channel.id
        })

      assert ids("aardvark") == [doc.id]
      assert ids("audit") == [doc.id]
      assert ids("zebra") == []

      [result] = Search.search("aardvark").results
      assert result.record.id == doc.id
      assert result.channel.id == ctx.channel.id
    end

    test "an image is indexed by filename and caption only" do
      png = File.read!(Path.expand("../support/files/red.png", __DIR__))

      {:ok, image} =
        Documents.create(%{
          filename: "screenshot-login.png",
          source: {:binary, png},
          caption: "broken button",
          user_id: user_fixture().id
        })

      assert ids("screenshot") == [image.id]
      assert ids("button") == [image.id]
      assert ids("IHDR") == []
    end

    test "deleting a document unindexes it" do
      doc = text_document("notes.txt", "capybara")
      assert ids("capybara") == [doc.id]

      {:ok, _} = Documents.delete(doc)
      assert ids("capybara") == []
      assert entry_count("document", doc.id) == 0
    end

    test "the backfill indexes documents without an entry, once" do
      doc = text_document("old.txt", "okapi")
      Repo.delete_all(from(e in Entry, where: e.source == "document"))
      assert ids("okapi") == []

      assert Backfill.run() == 1
      assert ids("okapi") == [doc.id]

      assert Backfill.run() == 0
      assert entry_count("document", doc.id) == 1
    end
  end

  describe "tokenization" do
    setup ctx do
      post = fn body ->
        elem(Messages.post_user_message(ctx.channel.id, ctx.user.id, body), 1).id
      end

      %{post: post}
    end

    test "code and paths match as typed and by their parts", %{post: post} do
      code = post.("the retry calls enqueue_charge twice in lib/canopy/messages.ex handle_info/2")

      for query <- [
            "enqueue_charge",
            "charge",
            "lib/canopy/messages.ex",
            "messages.ex",
            "handle_info/2"
          ] do
        assert ids(query) == [code], "expected #{query} to match"
      end
    end

    test "diacritics fold, and prefixes match", %{post: post} do
      cafe = post.("meet at the café")
      enqueue = post.("enqueue it")

      assert ids("cafe") == [cafe]
      assert ids("enq*") == [enqueue]
      assert ids("enq") == []
      assert ids("enq", prefix_last: true) == [enqueue]
      # a trailing space means the word is finished
      assert ids("enq ", prefix_last: true) == []
    end

    test "there are no matches inside a word (the known gap)", %{post: post} do
      worker = post.("PaymentWorker retries twice")

      assert ids("worker") == []
      assert ids("Payment*") == [worker]
    end

    test "operators and punctuation are terms or dropped, never syntax" do
      assert Query.to_fts(~s(retr* "database layer" uniq)) == ~s("retr"* "database layer" "uniq")
      assert Query.to_fts("a AND b") == ~s("a" "AND" "b")
      assert Query.to_fts("( \" ) -- ;") == ""

      assert Query.to_fts("enqueue_charge retr", prefix_last: true) ==
               ~s("enqueue_charge" "retr"*)

      assert Query.to_fts(~s(retr "phrase"), prefix_last: true) == ~s("retr" "phrase")
      assert Query.to_fts("r", prefix_last: true) == ~s("r")
    end

    test "fewer than two letters or digits search nothing", %{post: post} do
      post.("x marks the spot")
      assert Search.search("x").results == []
      assert Search.search("x", min_chars: 1).results != []
    end
  end

  describe "ranking and filters" do
    test "a filename hit outranks a path hit, which outranks a body hit", ctx do
      {:ok, body} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "the ledger is fine")
      path = turn(ctx, %{"files" => ["lib/ledger.ex"]})
      file = text_document("ledger.md", "nothing here")

      assert ids("ledger", sort: :rank) == [file.id, path.id, body.id]
    end

    test "equal text ranks the newer row first; newest sorts by time", ctx do
      {:ok, old} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "identical wording")
      {:ok, new} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "identical wording")
      backdate(old, 30)

      assert ids("identical") == [new.id, old.id]

      {:ok, longer} =
        Messages.post_user_message(
          ctx.channel.id,
          ctx.user.id,
          "identical but with many more words"
        )

      backdate(longer, -1)
      assert ids("identical", sort: :newest) == [longer.id, new.id, old.id]
    end

    test "channel (with documents attached there), agent, user and sources", ctx do
      other = channel_fixture()
      {:ok, mine} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "quokka one")
      {:ok, theirs} = Messages.post_agent_message(other.id, other.owner_agent_id, "quokka two")
      doc = text_document("quokka.txt", "hi", %{origin_channel_id: other.id})

      assert Enum.sort(ids("quokka", channel_ids: [ctx.channel.id])) == [mine.id]

      {:ok, _} =
        Messages.post_user_message(ctx.channel.id, ctx.user.id, "see file", attachments: [doc.id])

      assert Enum.sort(ids("quokka", channel_ids: [ctx.channel.id])) ==
               Enum.sort([mine.id, doc.id])

      assert ids("quokka", agent: other.owner_agent_id) == [theirs.id]
      assert Enum.sort(ids("quokka", agent: :user)) == Enum.sort([mine.id, doc.id])
      assert ids("quokka", sources: ["document"]) == [doc.id]

      %{counts: counts, total: total} = Search.search("quokka", sources: ["document"])
      assert counts == %{"message" => 2, "turn" => 0, "document" => 1}
      assert total == 1
    end

    test "a date range includes the whole `to` day in local time", ctx do
      {:ok, today} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "wombat today")
      {:ok, old} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "wombat old")
      backdate(old, 10)

      local_today =
        DateTime.utc_now() |> Canopy.Schedules.When.to_local_naive() |> NaiveDateTime.to_date()

      assert ids("wombat", from: local_today, to: local_today) == [today.id]
      assert ids("wombat", to: Date.add(local_today, -5)) == [old.id]
      assert length(ids("wombat", from: Date.add(local_today, -11))) == 2
    end

    test "archived channels are left out unless asked for; DMs are in", ctx do
      {:ok, archived} = Messages.post_user_message(ctx.channel.id, ctx.user.id, "lemur archived")
      {:ok, _} = Channels.archive(Channels.get!(ctx.channel.id))
      {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.agent)
      {:ok, in_dm} = Messages.post_user_message(dm.id, ctx.user.id, "lemur in a dm")

      assert ids("lemur") == [in_dm.id]
      assert Enum.sort(ids("lemur", include_archived: true)) == Enum.sort([archived.id, in_dm.id])
    end

    test "paging stops at #{Search.max_rows()} rows", ctx do
      for _ <- 1..3, do: Messages.post_user_message(ctx.channel.id, ctx.user.id, "tapir")

      assert length(ids("tapir", limit: 2)) == 2
      assert length(ids("tapir", limit: 2, offset: 2)) == 1
      assert ids("tapir", offset: Search.max_rows()) == []
    end
  end
end
