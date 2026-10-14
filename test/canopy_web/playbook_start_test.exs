defmodule CanopyWeb.PlaybookStartTest do
  use Canopy.DataCase, async: false

  import Mox
  import Canopy.Fixtures
  import Canopy.PlaybookHelpers

  alias Canopy.{Channels, Repo}
  alias Canopy.Playbooks.Run
  alias CanopyWeb.PlaybookStart

  setup :set_mox_global

  setup do
    ctx = scenario()
    on_exit(&stop_channels/0)
    stub_engine(self(), ctx.repository)
    playbook = playbook_fixture("ship", [{"a", "A", "coordinator"}])
    Map.put(ctx, :playbook, playbook)
  end

  defp params(ctx, more) do
    Map.merge(
      %{"playbook_id" => ctx.playbook.id, "coordinator_id" => ctx.agent.id, "brief" => ""},
      more
    )
  end

  defp runs, do: Repo.aggregate(Run, :count)

  describe "channel_groups/0" do
    test "open channels by repository, both by name; DMs, archived channels and empty repositories left out",
         ctx do
      zeta = repository_fixture(name: "zeta")
      _empty = repository_fixture(name: "empty")
      b = channel_fixture(%{repository_id: zeta.id, name: "bravo"})
      a = channel_fixture(%{repository_id: zeta.id, name: "alpha"})
      gone = channel_fixture(%{repository_id: zeta.id, name: "gone"})
      {:ok, _} = Channels.archive(gone)
      {:ok, _dm} = Channels.ensure_dm(zeta.id, ctx.agent)

      groups = PlaybookStart.channel_groups()

      assert Enum.map(groups, &elem(&1, 0)) == Enum.sort([ctx.repository.name, "zeta"])
      refute List.keymember?(groups, "empty", 0)

      assert {"zeta", [%{id: a_id, name: "alpha"}, %{id: b_id, name: "bravo"}]} =
               List.keyfind(groups, "zeta", 0)

      assert {a_id, b_id} == {a.id, b.id}
    end

    test "run_active? marks channels with a run in progress, awaiting approval included", ctx do
      other = channel_fixture(%{repository_id: ctx.repository.id, owner_agent_id: ctx.agent.id})

      {:ok, run} =
        PlaybookStart.start(
          params(ctx, %{"runs_in" => "existing", "channel_id" => ctx.channel.id})
        )

      active? = fn ->
        {_, channels} = List.keyfind(PlaybookStart.channel_groups(), ctx.repository.name, 0)
        Map.new(channels, &{&1.id, &1.run_active?})
      end

      assert active?.() == %{ctx.channel.id => true, other.id => false}

      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: "awaiting_approval"])
      assert active?.()[ctx.channel.id]

      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: "completed"])
      refute active?.()[ctx.channel.id]
    end
  end

  describe "start/2 from the Start page" do
    test "existing: runs in the channel, ignoring any channel_name", ctx do
      assert {:ok, run} =
               PlaybookStart.start(
                 params(ctx, %{
                   "runs_in" => "existing",
                   "channel_id" => ctx.channel.id,
                   "channel_name" => "should-not-exist"
                 })
               )

      assert run.channel_id == ctx.channel.id
      assert run.brief == ""
      refute Channels.get_by_name(ctx.repository.id, "should-not-exist")
    end

    test "the older \"current\" works as existing", ctx do
      assert {:ok, run} =
               PlaybookStart.start(
                 params(ctx, %{"runs_in" => "current", "channel_id" => ctx.channel.id})
               )

      assert run.channel_id == ctx.channel.id
    end

    test "existing: no channel picked asks for one", ctx do
      assert {:error, "pick a channel"} =
               PlaybookStart.start(params(ctx, %{"runs_in" => "existing"}))

      assert {:error, "pick a channel"} =
               PlaybookStart.start(params(ctx, %{"runs_in" => "existing", "channel_id" => ""}))
    end

    test "existing: a DM or an archived channel counts as none picked", ctx do
      {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.agent)
      gone = channel_fixture(%{repository_id: ctx.repository.id, name: "gone"})
      {:ok, _} = Channels.archive(gone)
      before = runs()

      for id <- [dm.id, gone.id, "no-such-channel"] do
        assert {:error, "pick a channel"} =
                 PlaybookStart.start(params(ctx, %{"runs_in" => "existing", "channel_id" => id}))
      end

      assert runs() == before
    end

    test "existing: a channel with a run in progress is refused in the page's words", ctx do
      {:ok, _} =
        PlaybookStart.start(
          params(ctx, %{"runs_in" => "existing", "channel_id" => ctx.channel.id})
        )

      assert {:error, reason} =
               PlaybookStart.start(
                 params(ctx, %{"runs_in" => "existing", "channel_id" => ctx.channel.id})
               )

      assert reason ==
               "##{ctx.channel.name} already has a run in progress (ship); pick another channel or start a new one"
    end

    test "new: no brief names the channel after the playbook, then -2", ctx do
      new = %{"runs_in" => "new", "repository_id" => ctx.repository.id}

      assert {:ok, run} = PlaybookStart.start(params(ctx, new))
      assert Channels.get!(run.channel_id).name == "ship"

      assert {:ok, run} = PlaybookStart.start(params(ctx, new))
      assert Channels.get!(run.channel_id).name == "ship-2"
    end

    test "new: a typed name that's taken is refused, compared as Runs would name it", ctx do
      _foo = channel_fixture(%{repository_id: ctx.repository.id, name: "foo"})
      before = runs()

      for typed <- ["foo", "#Foo", " FOO "] do
        assert {:error, reason} =
                 PlaybookStart.start(
                   params(ctx, %{
                     "runs_in" => "new",
                     "repository_id" => ctx.repository.id,
                     "channel_name" => typed
                   })
                 )

        assert reason ==
                 "#foo already exists in #{ctx.repository.name}; pick another name, or choose Existing channel"
      end

      assert runs() == before
    end

    test "new: an archived channel's name is taken too", ctx do
      old = channel_fixture(%{repository_id: ctx.repository.id, name: "old"})
      {:ok, _} = Channels.archive(old)
      before = runs()

      assert {:error, reason} =
               PlaybookStart.start(
                 params(ctx, %{
                   "runs_in" => "new",
                   "repository_id" => ctx.repository.id,
                   "channel_name" => "old"
                 })
               )

      assert reason ==
               "#old already exists in #{ctx.repository.name}; pick another name, or choose Existing channel"

      assert runs() == before
    end

    test "new: a typed name matching a taken one only after Runs trims dashes or cuts it to 50 is refused",
         ctx do
      long = String.duplicate("a", 50)
      _foo = channel_fixture(%{repository_id: ctx.repository.id, name: "foo"})
      _long = channel_fixture(%{repository_id: ctx.repository.id, name: long})
      before = runs()

      for {typed, taken} <- [{"-foo-", "foo"}, {long <> "-and-more", long}] do
        assert {:error, reason} =
                 PlaybookStart.start(
                   params(ctx, %{
                     "runs_in" => "new",
                     "repository_id" => ctx.repository.id,
                     "channel_name" => typed
                   })
                 )

        assert reason =~ "##{taken} already exists in #{ctx.repository.name}"
      end

      assert runs() == before
    end

    test "new: a typed name that normalises to nothing never makes a nameless channel", ctx do
      # it counts as no name: the playbook's, then -2 and on
      for {typed, name} <- [{"#", "ship"}, {"-", "ship-2"}, {"---", "ship-3"}] do
        assert {:ok, run} =
                 PlaybookStart.start(
                   params(ctx, %{
                     "runs_in" => "new",
                     "repository_id" => ctx.repository.id,
                     "channel_name" => typed
                   })
                 )

        assert Channels.get!(run.channel_id).name == name
      end
    end

    test "new: a name that cleans to nothing takes the brief's words, like no name", ctx do
      for typed <- [" # ", "#--"] do
        assert {:ok, run} =
                 PlaybookStart.start(
                   params(ctx, %{
                     "runs_in" => "new",
                     "repository_id" => ctx.repository.id,
                     "channel_name" => typed,
                     "brief" => "Fix the login bug"
                   })
                 )

        assert Channels.get!(run.channel_id).name =~ ~r/^ship-fix-the-login-bug(-2)?$/
      end

      refute Repo.exists?(from(c in Channels.Channel, where: c.name == ""))
    end

    test "new: a brief over 8000 characters is refused and leaves no channel behind", ctx do
      channels = length(Channels.list())

      assert {:error, "the brief is too long (at most 8000 characters)"} =
               PlaybookStart.start(
                 params(ctx, %{
                   "runs_in" => "new",
                   "repository_id" => ctx.repository.id,
                   "brief" => String.duplicate("x", 8_001)
                 })
               )

      assert length(Channels.list()) == channels
    end

    test "existing: a brief of 8000 characters, padded with whitespace, starts", ctx do
      brief = "  \n" <> String.duplicate("x", 8_000) <> "\n  "

      assert {:ok, run} =
               PlaybookStart.start(
                 params(ctx, %{
                   "runs_in" => "existing",
                   "channel_id" => ctx.channel.id,
                   "brief" => brief
                 })
               )

      assert String.length(run.brief) == 8_000
    end

    test "existing: a run awaiting approval is refused in the page's words", ctx do
      {:ok, run} =
        PlaybookStart.start(
          params(ctx, %{"runs_in" => "existing", "channel_id" => ctx.channel.id})
        )

      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: "awaiting_approval"])

      assert {:error, "#" <> _ = reason} =
               PlaybookStart.start(
                 params(ctx, %{"runs_in" => "current", "channel_id" => ctx.channel.id})
               )

      assert reason =~ "already has a run in progress (ship); pick another channel"
    end

    test "a runs_in that isn't new is treated as existing", ctx do
      for runs_in <- [nil, "bogus"] do
        assert {:error, "pick a channel"} =
                 PlaybookStart.start(params(ctx, %{"runs_in" => runs_in}))
      end
    end

    test "new: no repository asks for one", ctx do
      assert {:error, "pick a repository"} =
               PlaybookStart.start(params(ctx, %{"runs_in" => "new"}))
    end
  end

  describe "start/2 from the run panel" do
    test "always runs in its channel: runs_in and channel_name are ignored", ctx do
      assert {:ok, run} =
               PlaybookStart.start(
                 params(ctx, %{
                   "runs_in" => "new",
                   "repository_id" => ctx.repository.id,
                   "channel_name" => "crafted"
                 }),
                 ctx.channel
               )

      assert run.channel_id == ctx.channel.id
      refute Channels.get_by_name(ctx.repository.id, "crafted")
    end

    test "in a DM without the playbook's agents it is refused and nothing starts", ctx do
      {:ok, dm} = Channels.ensure_dm(ctx.repository.id, ctx.agent)
      other = agent_fixture()
      before = runs()

      assert {:error, reason} =
               PlaybookStart.start(
                 %{"playbook_id" => ctx.playbook.id, "coordinator_id" => other.id, "brief" => ""},
                 dm
               )

      # the run panel has no name field: a new channel is the Playbooks page's
      assert reason ==
               "a DM keeps its agents and this run needs others (the coordinator or the roster); " <>
                 "start it in a channel, or in a new one from the Playbooks page"

      assert runs() == before
    end

    test "the hint is always this channel, plus the team", ctx do
      old = playbook_fixture("old-new", [{"a", "A", "coordinator"}], "channel: new\n")
      form = PlaybookStart.form(%{"playbook_id" => old.id}, [old], ctx.channel)
      assert form[:hint].value == "Runs in this channel."

      team = team_fixture([ctx.agent], %{name: "crew"})

      teamed =
        playbook_fixture("teamed", [{"a", "A", "coordinator"}], "team: #{team.name}\n")

      form = PlaybookStart.form(%{"playbook_id" => teamed.id}, [teamed], ctx.channel)
      assert form[:hint].value == "Runs in this channel. @crew joins it."
    end
  end
end
