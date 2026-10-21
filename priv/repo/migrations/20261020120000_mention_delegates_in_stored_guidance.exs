defmodule Canopy.Repo.Migrations.MentionDelegatesInStoredGuidance do
  use Ecto.Migration

  # The starter guidance used to tell agents not to @mention a delegate in a
  # post about its delegation (the mention woke it a second time); agents put
  # the name in backticks instead. The runtime no longer wakes a delegate
  # again for that mention, so the guidance now asks for the @mention. Seeds
  # only create what is missing, so installs keep the old text: this rewrites
  # it in the seeded project manager's instructions and the seeded bug-fix
  # and feature-build playbooks. Only where the old passage is there verbatim
  # (as the seed stored it, line breaks included): a user's edit of it stays.
  # Plain SQL, so later schema changes cannot break it; running it again
  # changes nothing.

  @project_manager {
    """
    A delegation
    already wakes the delegate with the task, so a status post about it
    names the delegation id rather than @mentioning them again. Keep the channel
    task current, check in on stalled work with a scheduled task rather than
    repeated messages, and summarise status for the user in a few lines when
    asked. Bring a whole team into a channel with canopy_channel_add_members
    and a team name, then mention the team once with the plan. Don't assign
    or pass locks; agents acquire them themselves, and Canopy hands a lock to
    whoever is next in line. When asked to run a playbook, start it with
    canopy_playbook_start and follow it step by step; delegate each step to
    its owner. You do not implement; you coordinate, and you stop when the plan is
    clear and owned.\
    """,
    """
    A delegation
    already wakes the delegate with the task; a status post about it
    @mentions them, which doesn't wake them again while they work on it.
    Keep the channel task current, check in on stalled work with a scheduled
    task rather than repeated messages, and summarise status for the user in
    a few lines when asked. Bring a whole team into a channel with
    canopy_channel_add_members and a team name, then mention the team once
    with the plan. Don't assign or pass locks; agents acquire them
    themselves, and Canopy hands a lock to whoever is next in line. When
    asked to run a playbook, start it with canopy_playbook_start and follow
    it step by step; delegate each step to its owner. You do not implement;
    you coordinate, and you stop when the plan is clear and owned.\
    """
  }

  @bug_fix {
    "and what done looks like. Don't also\n  @mention the delegate.\n",
    "and what done looks like. A post about\n  it @mentions the delegate; that doesn't wake them again while they work on it.\n"
  }

  @feature_build {
    "and what done looks like. Don't also @mention the delegate.\n",
    "and what done looks like. A post about it @mentions the delegate; that\n  doesn't wake them again while they work on it.\n"
  }

  def up, do: rewrite(repo(), :up)

  def down, do: rewrite(repo(), :down)

  @doc false
  def rewrite(repo, direction) do
    {old, new} = pair(@project_manager, direction)

    repo.query!(
      """
      UPDATE agents SET system_prompt = replace(system_prompt, ?1, ?2)
      WHERE name = 'project-manager' AND instr(system_prompt, ?1) > 0
      """,
      [old, new]
    )

    for {name, texts} <- [{"bug-fix", @bug_fix}, {"feature-build", @feature_build}] do
      {old, new} = pair(texts, direction)

      # a new lock version, so an editor opened on the old text can't save over it
      repo.query!(
        """
        UPDATE playbooks
        SET body = replace(body, ?1, ?2), lock_version = lock_version + 1
        WHERE name = ?3 AND source = 'seed' AND instr(body, ?1) > 0
        """,
        [old, new, name]
      )
    end

    :ok
  end

  defp pair({old, new}, :up), do: {old, new}
  defp pair({old, new}, :down), do: {new, old}
end
