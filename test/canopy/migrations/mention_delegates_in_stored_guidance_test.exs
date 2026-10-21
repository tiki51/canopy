defmodule Canopy.Migrations.MentionDelegatesInStoredGuidanceTest do
  use Canopy.DataCase, async: false

  alias Canopy.{Agents, Playbooks, Repo, Seeds}

  @migration Canopy.Repo.Migrations.MentionDelegatesInStoredGuidance
  @path "priv/repo/migrations/20261020120000_mention_delegates_in_stored_guidance.exs"

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    {:ok, _} = Seeds.run()
    :ok
  end

  # The migration file is loaded at run time, so it is called dynamically.
  defp rewrite(direction), do: apply(@migration, :rewrite, [Repo, direction])

  defp prompt, do: Agents.get_by_name("project-manager").system_prompt
  defp body(name), do: Playbooks.get_by_name(name).body

  defp set_prompt(text),
    do: Repo.query!("UPDATE agents SET system_prompt = ?1 WHERE name = 'project-manager'", [text])

  defp set_body(name, text, source \\ "seed"),
    do:
      Repo.query!("UPDATE playbooks SET body = ?1, source = ?2 WHERE name = ?3", [
        text,
        source,
        name
      ])

  test "the old seeded text becomes the current template's, and running again changes nothing" do
    current = {prompt(), body("bug-fix"), body("feature-build")}
    assert elem(current, 1) == Playbooks.bug_fix_text()
    assert elem(current, 2) == Playbooks.feature_build_text()

    # back to the text an older version seeded
    rewrite(:down)

    assert prompt() =~
             "so a status post about it\nnames the delegation id rather than @mentioning"

    assert body("bug-fix") =~ "Don't also\n  @mention the delegate."
    assert body("feature-build") =~ "Don't also @mention the delegate."
    refute body("bug-fix") =~ "doesn't wake them again"

    rewrite(:up)
    assert {prompt(), body("bug-fix"), body("feature-build")} == current
    version = Playbooks.get_by_name("bug-fix").lock_version

    rewrite(:up)
    assert {prompt(), body("bug-fix"), body("feature-build")} == current
    assert Playbooks.get_by_name("bug-fix").lock_version == version
  end

  test "a user's edit of the old passage, or a playbook of their own, stays as it is" do
    rewrite(:down)

    edited = String.replace(prompt(), "names the delegation id", "cites the delegation id")
    set_prompt(edited)

    edited_bug_fix =
      String.replace(body("bug-fix"), "Don't also\n  @mention", "Never\n  @mention")

    set_body("bug-fix", edited_bug_fix)

    # the old text verbatim, but in a playbook the user made their own
    own = body("feature-build")
    set_body("feature-build", own, "user")

    rewrite(:up)

    assert prompt() == edited
    assert body("bug-fix") == edited_bug_fix
    assert body("feature-build") == own
  end
end
