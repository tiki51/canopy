defmodule Canopy.PlaybooksTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.Playbooks
  alias Canopy.Playbooks.{Definition, Runs}

  def playbook_text(name, extra \\ "") do
    """
    ---
    name: #{name}
    description: The #{name} process.
    #{extra}steps:
      - id: plan
        title: Plan
        owner: coordinator
    ---

    ## plan

    Plan it.
    """
  end

  test "create, update, and delete; name and description come from the text" do
    Playbooks.subscribe()
    assert {:ok, playbook} = Playbooks.create(%{body: playbook_text("alpha")})
    assert playbook.name == "alpha"
    assert playbook.description == "The alpha process."
    assert playbook.enabled
    assert playbook.source == "user"
    assert_receive {:playbooks, :changed}

    assert {:ok, playbook} = Playbooks.update(playbook, %{body: playbook_text("alpha-two")})
    assert playbook.name == "alpha-two"
    assert Playbooks.get_by_name("alpha-two").id == playbook.id

    assert {:ok, _} = Playbooks.delete(playbook)
    assert Playbooks.get(playbook.id) == nil
  end

  test "a text that does not parse is an error on body, one per reason" do
    assert {:error, changeset} = Playbooks.create(%{body: "---\nname: x\n---\n"})
    errors = errors_on(changeset).body
    assert "description is missing" in errors
    assert "steps is missing" in errors
    assert Enum.any?(errors, &(&1 =~ "2 to 40"))
  end

  test "names are unique" do
    {:ok, _} = Playbooks.create(%{body: playbook_text("dup")})
    assert {:error, changeset} = Playbooks.create(%{body: playbook_text("dup")})
    assert "is already a playbook's name" in errors_on(changeset).name
  end

  test "seeding creates the starter playbooks once and leaves an edited one alone" do
    assert [{:created, "bug-fix"}, {:created, "feature-build"}] = Playbooks.seed()
    playbook = Playbooks.get_by_name("bug-fix")
    assert playbook.source == "seed"

    assert %{source: "seed", enabled: true, body: body} = Playbooks.get_by_name("feature-build")
    assert body == Playbooks.feature_build_text()

    edited = String.replace(playbook.body, "Triage and scope", "Triage")
    {:ok, _} = Playbooks.update(playbook, %{body: edited})
    assert [{:exists, "bug-fix"}, {:exists, "feature-build"}] = Playbooks.seed()
    assert Enum.map(Playbooks.seed(), &elem(&1, 1)) == Playbooks.seed_names()
    assert Playbooks.get_by_name("bug-fix").body =~ "title: Triage\n"
  end

  test "seeding never replaces an older feature-build, and a run on it keeps the old ending" do
    older =
      String.replace(
        Playbooks.feature_build_text(),
        "    approval: user\n    on_reject: build\n---",
        "---"
      )

    assert older != Playbooks.feature_build_text()
    {:ok, _} = Playbooks.create(%{body: older, source: "seed"})

    assert {:exists, "feature-build"} in Playbooks.seed()
    playbook = Playbooks.get_by_name("feature-build")
    assert playbook.body == older

    {:ok, d} = Playbooks.definition(playbook)
    assert %{approval: false, on_reject: nil} = Definition.step(d, "sign-off")
  end

  test "duplicate makes a disabled copy under a free name" do
    {:ok, original} = Playbooks.create(%{body: playbook_text("orig")})
    assert {:ok, copy} = Playbooks.duplicate(original)
    assert copy.name == "orig-copy"
    refute copy.enabled
    assert {:ok, again} = Playbooks.duplicate(original)
    assert again.name == "orig-copy-2"
  end

  test "for_prompt/0 lists enabled playbooks, capped, and says when there are none" do
    assert Playbooks.for_prompt() == "No playbooks are defined yet."

    {:ok, _} = Playbooks.create(%{body: playbook_text("visible")})
    {:ok, hidden} = Playbooks.create(%{body: playbook_text("hidden")})
    {:ok, _} = Playbooks.set_enabled(hidden, false)

    text = Playbooks.for_prompt()
    assert text =~ "Playbooks you can run with canopy_playbook_start:"
    assert text =~ "- visible — The visible process."
    refute text =~ "hidden"

    for n <- 1..25, do: {:ok, _} = Playbooks.create(%{body: playbook_text("many-#{n}")})
    capped = Playbooks.for_prompt()
    assert length(String.split(capped, "\n- ")) - 1 <= 20
    assert capped =~ "more; canopy_playbooks_list shows all"
    assert String.length(capped) < 2_200
  end

  test "an agent's draft is saved disabled, replaces its own draft, and never someone else's playbook" do
    agent = agent_fixture()
    assert {:ok, draft} = Playbooks.save_draft(agent, playbook_text("drafted"))
    refute draft.enabled
    assert draft.source == "agent"
    assert draft.created_by_agent_id == agent.id

    assert {:ok, again} = Playbooks.save_draft(agent, playbook_text("drafted", "inputs: more\n"))
    assert again.id == draft.id

    {:ok, _} = Playbooks.create(%{body: playbook_text("theirs")})
    assert {:error, reason} = Playbooks.save_draft(agent, playbook_text("theirs"))
    assert reason =~ "already exists"

    {:ok, enabled} = Playbooks.set_enabled(again, true)
    assert {:error, _} = Playbooks.save_draft(agent, playbook_text(enabled.name))

    assert {:error, reason} = Playbooks.save_draft(agent, "not a playbook")
    assert reason =~ "does not parse"
  end

  test "delete is refused while a run is in progress; finished runs keep their text" do
    ctx = scenario()
    {:ok, playbook} = Playbooks.create(%{body: playbook_text("busy")})

    {:ok, run, false} =
      Runs.start(%{
        playbook: playbook,
        channel: ctx.channel,
        coordinator: ctx.agent,
        started_by_agent_id: ctx.agent.id,
        brief: "go"
      })

    assert Playbooks.active_run_counts() == %{playbook.id => 1}
    assert {:error, reason} = Playbooks.delete(playbook)
    assert reason =~ "run in progress"

    {:ok, _run, :cancelled} = Runs.cancel(run, :user, "done")
    assert {:ok, _} = Playbooks.delete(playbook)
    finished = Runs.get!(run.id)
    assert finished.playbook_id == nil
    assert finished.definition =~ "name: busy"
  end

  describe "set_starred/2" do
    test "stars without an edit: no lock_version or updated_at bump; again keeps the time" do
      {:ok, playbook} = Playbooks.create(%{body: playbook_text("starry")})
      Playbooks.subscribe()

      assert {:ok, starred} = Playbooks.set_starred(playbook, true)
      assert %DateTime{} = starred.starred_at
      assert starred.lock_version == playbook.lock_version
      assert starred.updated_at == playbook.updated_at
      assert_receive {:playbooks, :changed}

      assert {:ok, again} = Playbooks.set_starred(playbook, true)
      assert again.starred_at == starred.starred_at

      # an editor still holding the unstarred struct neither clears the star nor goes stale
      assert {:ok, edited} = Playbooks.update(playbook, %{body: playbook_text("starry-two")})
      assert edited.starred_at == starred.starred_at
      assert Playbooks.get!(playbook.id).starred_at == starred.starred_at

      assert {:ok, unstarred} = Playbooks.set_starred(edited, false)
      assert unstarred.starred_at == nil
      assert_receive {:playbooks, :changed}
    end

    test "a draft can't be starred; disabling keeps a star; a deleted one is an error" do
      {:ok, draft} = Playbooks.create(%{body: playbook_text("drafty"), enabled: false})

      assert {:error, "drafts can't be starred; enable it first"} =
               Playbooks.set_starred(draft, true)

      {:ok, enabled} = Playbooks.set_enabled(draft, true)
      {:ok, starred} = Playbooks.set_starred(enabled, true)
      {:ok, disabled} = Playbooks.set_enabled(starred, false)
      assert disabled.starred_at == starred.starred_at
      # unstarring a draft always works
      assert {:ok, %{starred_at: nil}} = Playbooks.set_starred(disabled, false)

      # a duplicate starts unstarred
      {:ok, enabled} = Playbooks.set_enabled(Playbooks.get!(draft.id), true)
      {:ok, starred} = Playbooks.set_starred(enabled, true)
      {:ok, copy} = Playbooks.duplicate(starred)
      assert copy.starred_at == nil

      {:ok, _} = Playbooks.delete(starred)

      assert {:error, "that playbook no longer exists"} = Playbooks.set_starred(starred, true)
      assert {:error, "that playbook no longer exists"} = Playbooks.set_starred(starred, false)
    end

    test "list/0 loads the star" do
      {:ok, playbook} = Playbooks.create(%{body: playbook_text("listed-star")})
      {:ok, _} = Playbooks.set_starred(playbook, true)
      assert %{starred_at: %DateTime{}} = Enum.find(Playbooks.list(), &(&1.id == playbook.id))
    end
  end

  test "active_runs/0: live runs per playbook, oldest first, with position and step count" do
    one = scenario()
    two = scenario()
    {:ok, playbook} = Playbooks.create(%{body: two_steps("running")})

    start = fn ctx ->
      {:ok, run, false} =
        Runs.start(%{
          playbook: playbook,
          channel: ctx.channel,
          coordinator: ctx.agent,
          started_by_agent_id: ctx.agent.id,
          brief: "go"
        })

      run
    end

    first = start.(one)
    second = start.(two)
    {:ok, second, {:step, "build"}} = Runs.advance(second, :user)

    assert [a, b] = Playbooks.active_runs()[playbook.id]

    assert a == %{
             run_id: first.id,
             channel_id: one.channel.id,
             channel_name: one.channel.name,
             status: "active",
             position: 1,
             steps: 2
           }

    assert %{run_id: id, position: 2, steps: 2, status: "active"} = b
    assert id == second.id

    # awaiting approval counts; a run with no current step is listed without a position
    Repo.update_all(from(r in Canopy.Playbooks.Run, where: r.id == ^first.id),
      set: [status: "awaiting_approval", current_step: nil]
    )

    assert [%{status: "awaiting_approval", position: nil, steps: 2}, _] =
             Playbooks.active_runs()[playbook.id]

    # finished runs drop out
    {:ok, _, :cancelled} = Runs.cancel(Runs.get!(second.id), :user, "done")
    assert [%{run_id: only}] = Playbooks.active_runs()[playbook.id]
    assert only == first.id
    assert map_size(Playbooks.active_run_counts()) == map_size(Playbooks.active_runs())
  end

  defp two_steps(name) do
    """
    ---
    name: #{name}
    description: The #{name} process.
    steps:
      - id: plan
        title: Plan
        owner: coordinator
      - id: build
        title: Build
        owner: coordinator
    ---

    ## plan

    Plan it.

    ## build

    Build it.
    """
  end

  # 12
  test "an agent replaces only its own untouched draft; a user edit claims it" do
    agent = agent_fixture()
    other = agent_fixture()
    {:ok, draft} = Playbooks.save_draft(agent, playbook_text("claimed"))

    # another agent cannot replace it
    assert {:error, reason} =
             Playbooks.save_draft(other, playbook_text("claimed", "inputs: mine\n"))

    assert reason =~ "another agent's draft"

    # the user edits it: it is theirs now
    {:ok, edited} = Playbooks.update(draft, %{body: playbook_text("claimed", "inputs: edited\n")})
    assert edited.source == "user"

    assert {:error, reason} =
             Playbooks.save_draft(agent, playbook_text("claimed", "inputs: again\n"))

    assert reason =~ "already exists"
    assert Playbooks.get!(draft.id).body =~ "inputs: edited"
  end

  # 12
  test "enabling approves the text the user saw: a draft replaced since is not enabled" do
    agent = agent_fixture()
    {:ok, draft} = Playbooks.save_draft(agent, playbook_text("seen"))
    seen_version = draft.lock_version

    {:ok, replaced} = Playbooks.save_draft(agent, playbook_text("seen", "inputs: swapped\n"))
    assert replaced.lock_version > seen_version

    assert {:error, :stale} = Playbooks.set_enabled(draft, true, seen_version)
    refute Playbooks.get!(draft.id).enabled

    assert {:ok, enabled} = Playbooks.set_enabled(replaced, true, replaced.lock_version)
    assert enabled.enabled

    # once enabled, the agent can no longer replace it
    assert {:error, _} = Playbooks.save_draft(agent, playbook_text("seen", "inputs: later\n"))
  end

  # 12 (stale editor)
  test "an edit from a stale page is refused" do
    {:ok, playbook} = Playbooks.create(%{body: playbook_text("edited-twice")})
    {:ok, _} = Playbooks.update(playbook, %{body: playbook_text("edited-twice", "inputs: a\n")})

    assert {:error, changeset} =
             Playbooks.update(playbook, %{body: playbook_text("edited-twice", "inputs: b\n")})

    assert Keyword.has_key?(changeset.errors, :lock_version)
  end

  # 13
  test "the list carries who wrote each draft" do
    agent = agent_fixture(name: "drafter-" <> unique_suffix())
    {:ok, _} = Playbooks.save_draft(agent, playbook_text("attributed"))
    [listed] = Enum.filter(Playbooks.list(), &(&1.name == "attributed"))
    assert listed.created_by.name == agent.name
  end
end
