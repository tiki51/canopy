defmodule Canopy.PlaybooksTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.Playbooks
  alias Canopy.Playbooks.Runs

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

  test "seeding creates bug-fix once and leaves an edited one alone" do
    assert [{:created, "bug-fix"}] = Playbooks.seed()
    playbook = Playbooks.get_by_name("bug-fix")
    assert playbook.source == "seed"

    edited = String.replace(playbook.body, "Triage and scope", "Triage")
    {:ok, _} = Playbooks.update(playbook, %{body: edited})
    assert [{:exists, "bug-fix"}] = Playbooks.seed()
    assert Playbooks.get_by_name("bug-fix").body =~ "title: Triage\n"
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
