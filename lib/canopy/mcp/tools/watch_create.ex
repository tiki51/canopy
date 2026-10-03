defmodule Canopy.MCP.Tools.WatchCreate do
  @moduledoc """
  Watch GitHub for something new and act on it: new pull requests, issues,
  failed CI runs, releases, or commits. Canopy checks with the user's `gh`
  CLI (no tokens spent while nothing changes) and, for each check that finds
  new items, wakes you with them and your instruction, or starts a playbook
  run per item. What already exists when you create the watch never fires.
  It is listed with your schedules; cancel it with canopy_schedule_cancel.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.{GitHub, Watches}
  alias Canopy.MCP.Tool

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :source, {:required, :string},
      description: "What to watch: prs, issues, ci_failures, releases, or commits."

    field :instruction, {:required, :string},
      description:
        "What to do when something new appears, as a note to your future self (or the playbook brief's instruction)."

    field :repo, :string,
      description: "owner/name on GitHub. Defaults to this channel's repository's GitHub remote."

    field :branch, :string,
      description: "prs: the base branch; ci_failures and commits: the branch."

    field :label, :string, description: "prs and issues: only items with this label."
    field :workflow_file, :string, description: "ci_failures: only this workflow, e.g. ci.yml."

    field :every, :string,
      description: "How often to check: 1m (default), 2m, 5m, 10m, 15m, 30m, or 1h."

    field :playbook, :string,
      description: "Start this playbook (you coordinate) for each new item instead of waking you."

    field :include_existing, :boolean,
      description: "Also fire for what exists now (normally only items that appear later fire)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      case Watches.create(%{
             channel: ctx.channel,
             agent: ctx.agent,
             created_by_agent_id: ctx.agent.id,
             instruction: Tool.blank_to_nil(Map.get(params, :instruction)),
             source: Map.get(params, :source),
             repo: Tool.blank_to_nil(Map.get(params, :repo)),
             branch: Map.get(params, :branch),
             label: Map.get(params, :label),
             workflow_file: Map.get(params, :workflow_file),
             every: Tool.blank_to_nil(Map.get(params, :every)),
             playbook: Tool.blank_to_nil(Map.get(params, :playbook)),
             include_existing: Map.get(params, :include_existing) == true
           }) do
        {:ok, watch} ->
          seen = Watches.seen_count(watch.id)
          then = if watch.playbook, do: "start #{watch.playbook} for each", else: "wake you"

          {:ok,
           "watching [#{watch.id}] #{GitHub.describe(watch.check)}, #{Watches.describe_every(watch.cron)}; " <>
             "#{seen} existing #{if seen == 1, do: "item", else: "items"} recorded as seen. " <>
             "New items will #{then}. Cancel with canopy_schedule_cancel."}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, "could not create the watch: " <> Tool.changeset_reason(changeset)}

        {:error, reason} when is_binary(reason) ->
          {:error, String.replace(reason, "@agent", "@" <> ctx.agent.name)}
      end
    end)
  end
end
