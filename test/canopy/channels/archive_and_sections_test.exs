defmodule Canopy.Channels.ArchiveAndSectionsTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Channels, Tasks}
  alias Canopy.Channels.{Channel, Section, Sections}

  setup do
    repository = repository_fixture()
    owner = agent_fixture()
    %{repository: repository, owner: owner}
  end

  defp create(ctx, attrs) do
    Channels.create(
      Map.merge(
        %{
          repository_id: ctx.repository.id,
          name: "ch-" <> unique_suffix(),
          owner_agent_id: ctx.owner.id
        },
        attrs
      )
    )
  end

  describe "create/1 with a section" do
    test "files the channel under an existing section, matched in any case", ctx do
      {:ok, section} = Sections.create(ctx.repository.id, "Releases")

      assert {:ok, %Channel{section_id: id, section: %Section{created?: false}}} =
               create(ctx, %{section: "releases"})

      assert id == section.id
    end

    test "creates a new section last and says so", ctx do
      {:ok, _} = Sections.create(ctx.repository.id, "First")
      assert {:ok, channel} = create(ctx, %{section: " Launch "})
      assert %Section{name: "Launch", position: 1, created?: true} = channel.section
      assert Channels.get!(channel.id).section.id == channel.section.id
    end

    test "blank or nil means no section", ctx do
      assert {:ok, %Channel{section_id: nil, section: nil}} = create(ctx, %{section: ""})
      assert {:ok, %Channel{section_id: nil}} = create(ctx, %{section: nil})
      assert {:ok, %Channel{section_id: nil}} = create(ctx, %{"section" => "  "})
      assert Sections.list(ctx.repository.id) == []
    end

    test "a too-long name is an error on the channel's :section and writes nothing", ctx do
      assert {:error, %Ecto.Changeset{data: %Channel{}} = changeset} =
               create(ctx, %{name: "too-long", section: String.duplicate("x", 41)})

      assert %{section: ["should be at most 40 character(s)"]} = errors_on(changeset)

      assert Canopy.MCP.Tool.changeset_reason(changeset) =~
               "section should be at most 40 character(s)"

      assert Sections.list(ctx.repository.id) == []
      assert Channels.get_by_name(ctx.repository.id, "too-long") == nil
    end

    test "a section name error shows beside a channel name error", ctx do
      assert {:error, changeset} =
               create(ctx, %{name: "Bad Name!", section: String.duplicate("x", 41)})

      errors = errors_on(changeset)
      assert errors[:section]
      assert errors[:name]
    end

    test "a failed create leaves no new section behind", ctx do
      {:ok, _} = create(ctx, %{name: "taken"})
      assert {:error, changeset} = create(ctx, %{name: "taken", section: "Fresh"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
      assert Sections.list(ctx.repository.id) == []
    end

    test "section_id must belong to the same repository", ctx do
      other = repository_fixture()
      {:ok, foreign} = Sections.create(other.id, "Elsewhere")
      assert {:error, changeset} = create(ctx, %{section_id: foreign.id})
      assert %{section_id: ["is not a section of this project"]} = errors_on(changeset)

      {:ok, own} = Sections.create(ctx.repository.id, "Here")
      assert {:ok, %Channel{section_id: id}} = create(ctx, %{section_id: own.id})
      assert id == own.id
    end
  end

  describe "the archive offer" do
    setup ctx do
      {:ok, channel} = create(ctx, %{topic: "Ship it"})
      Map.put(ctx, :channel, channel)
    end

    defp complete(channel, agent_id) do
      {:ok, task} =
        Tasks.update(Tasks.for_channel(channel.id), %{status: "completed"}, agent_id: agent_id)

      task
    end

    test "archive_offer?/1 matrix", ctx do
      channel = ctx.channel
      refute Channels.archive_offer?(channel)

      complete(channel, ctx.owner.id)
      done = Channels.get!(channel.id)
      assert Channels.archive_offer?(done)
      refute Channels.archive_offer?(%{done | status: "archived"})
      refute Channels.archive_offer?(%{done | kind: "dm"})
      refute Channels.archive_offer?(%{done | archive_offer_dismissed_at: DateTime.utc_now()})
      refute Channels.archive_offer?(%{done | task: %{done.task | status: "working"}})
    end

    test "archive_offer/1 names who completed it and when, reading the task fresh", ctx do
      stale = ctx.channel
      assert Channels.archive_offer(stale) == nil

      other = agent_fixture()
      complete(stale, other.id)

      # the struct still holds the open task it was loaded with
      assert stale.task.status == "open"

      assert %{title: "Ship it", by: :agent, agent_id: agent_id, completed_at: %DateTime{}} =
               Channels.archive_offer(stale)

      assert agent_id == other.id
      assert Channels.archive_offer(stale.id).agent_id == other.id
    end

    test "archive_offer/1 says the user completed it, not the task owner", ctx do
      complete(ctx.channel, nil)

      assert %{by: :user, agent_id: nil, completed_at: %DateTime{}} =
               Channels.archive_offer(ctx.channel)
    end

    test "archive_offer/1 credits the latest completion", ctx do
      task = complete(ctx.channel, ctx.owner.id)
      {:ok, _} = Tasks.update(task, %{status: "open"})
      complete(ctx.channel, nil)
      assert %{by: :user, agent_id: nil} = Channels.archive_offer(ctx.channel)
    end

    test "archive_offer/1 credits no one without a completing event, not even the owner", ctx do
      task = Tasks.for_channel(ctx.channel.id)
      assert task.owner_agent_id == ctx.owner.id
      task = task |> Ecto.Changeset.change(status: "completed") |> Repo.update!()

      assert %{by: nil, agent_id: nil, completed_at: completed_at} =
               Channels.archive_offer(ctx.channel)

      assert completed_at == task.updated_at
    end

    test "a task going from completed back to open hides the offer", ctx do
      task = complete(ctx.channel, ctx.owner.id)
      assert Channels.archive_offer?(Channels.get!(ctx.channel.id))
      {:ok, _} = Tasks.update(task, %{status: "open"})
      refute Channels.archive_offer?(Channels.get!(ctx.channel.id))
      assert Channels.archive_offer(ctx.channel) == nil
    end

    test "dismiss_archive_offer/1 is for good and idempotent", ctx do
      complete(ctx.channel, nil)
      Channels.subscribe()

      assert {:ok, %Channel{archive_offer_dismissed_at: %DateTime{} = at}} =
               Channels.dismiss_archive_offer(ctx.channel)

      assert_receive {:channels, :changed}

      assert {:ok, %Channel{archive_offer_dismissed_at: ^at}} =
               Channels.dismiss_archive_offer(Channels.get!(ctx.channel.id))

      assert Channels.archive_offer(ctx.channel) == nil
    end

    test "reopen keep_open: true dismisses the offer; plain reopen (Undo) doesn't", ctx do
      complete(ctx.channel, nil)
      {:ok, archived} = Channels.archive(ctx.channel)
      {:ok, undone} = Channels.reopen(archived)
      assert undone.archive_offer_dismissed_at == nil
      assert Channels.archive_offer?(undone)

      {:ok, archived} = Channels.archive(undone)
      {:ok, kept} = Channels.reopen(archived, keep_open: true)
      assert kept.status == "open"
      assert %DateTime{} = kept.archive_offer_dismissed_at
      refute Channels.archive_offer?(kept)
    end

    test "reopen keep_open: true with the task working or blocked dismisses nothing", ctx do
      for status <- ["working", "blocked"] do
        {:ok, channel} = create(ctx, %{})
        {:ok, task} = Tasks.update(Tasks.for_channel(channel.id), %{status: status})
        {:ok, archived} = Channels.archive(channel)
        {:ok, kept} = Channels.reopen(archived, keep_open: true)
        assert kept.archive_offer_dismissed_at == nil, status

        {:ok, _} = Tasks.update(task, %{status: "completed"})
        assert Channels.archive_offer?(Channels.get!(channel.id)), status
      end
    end

    # A2b: the task is still open at reopen
    test "reopen keep_open: true mid-task leaves the offer to show once the task is done",
         ctx do
      {:ok, archived} = Channels.archive(ctx.channel)
      {:ok, kept} = Channels.reopen(archived, keep_open: true)
      assert kept.status == "open"
      assert kept.archive_offer_dismissed_at == nil

      # an open channel reopened on purpose mid-task: still nothing dismissed
      {:ok, kept} = Channels.reopen(kept, keep_open: true)
      assert kept.archive_offer_dismissed_at == nil

      complete(ctx.channel, ctx.owner.id)
      assert Channels.archive_offer?(Channels.get!(ctx.channel.id))
      assert %{by: :agent} = Channels.archive_offer(ctx.channel)
    end

    test "reopen keep_open: true reads the task fresh, not the caller's copy", ctx do
      {:ok, archived} = Channels.archive(ctx.channel)
      # the task finishes while the page still holds the archived channel and its open task
      complete(ctx.channel, ctx.owner.id)
      assert archived.task.status == "open"

      {:ok, kept} = Channels.reopen(archived, keep_open: true)
      assert %DateTime{} = kept.archive_offer_dismissed_at
    end

    test "archive and reopen keep the section", ctx do
      {:ok, section} = Sections.create(ctx.repository.id, "S")
      {:ok, _} = Sections.move_channel(ctx.channel, section)
      {:ok, archived} = Channels.archive(Channels.get!(ctx.channel.id))
      assert archived.section_id == section.id
      {:ok, reopened} = Channels.reopen(archived)
      assert reopened.section_id == section.id
    end
  end

  describe "Tasks.update/3 and the sidebar" do
    setup ctx do
      {:ok, channel} = create(ctx, %{})
      Channels.subscribe()
      Map.put(ctx, :task, Tasks.for_channel(channel.id))
    end

    test "broadcasts when the status moves to or from completed", ctx do
      {:ok, task} = Tasks.update(ctx.task, %{status: "completed"})
      assert_receive {:channels, :changed}
      {:ok, _} = Tasks.update(task, %{status: "open"})
      assert_receive {:channels, :changed}
    end

    test "stays quiet for other changes", ctx do
      {:ok, task} = Tasks.update(ctx.task, %{title: "Renamed"})
      {:ok, _} = Tasks.update(task, %{status: "working"})
      refute_receive {:channels, :changed}
    end
  end
end
