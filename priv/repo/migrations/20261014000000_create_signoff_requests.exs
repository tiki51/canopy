defmodule Canopy.Repo.Migrations.CreateSignoffRequests do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  # Sign-off cards (`Canopy.Signoffs`). The backfill gives every playbook step
  # already held for the user's approval a pending card, so the run panel
  # never needs a card-less Approve. Plain queries on table names, never the
  # app's schemas, so a later field on `SignoffRequest` cannot break it.

  def up do
    create table(:signoff_requests, primary_key: false) do
      add :id, :string, primary_key: true
      add :channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false
      # who asked; nil once that agent is deleted, or for a run with no coordinator
      add :agent_id, references(:agents, type: :string, on_delete: :nilify_all)
      add :run_id, references(:playbook_runs, type: :string, on_delete: :delete_all)

      add :playbook_step_id,
          references(:playbook_steps, type: :string, on_delete: :delete_all)

      # the step's key, e.g. "tech-design"
      add :step_id, :string
      add :title, :string, null: false
      add :question, :text, null: false
      add :summary, :text
      add :options, {:array, :map}, null: false, default: "[]"
      add :document_ids, {:array, :string}, null: false, default: "[]"
      add :status, :string, null: false, default: "pending"
      add :choice, :string
      add :choice_index, :integer
      add :note, :text
      add :resolved_by, :string
      add :message_id, references(:messages, type: :string, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signoff_requests, [:channel_id, :status])
    create index(:signoff_requests, [:run_id])

    create unique_index(:signoff_requests, [:playbook_step_id],
             where: "status = 'pending'",
             name: :signoff_requests_one_pending_per_step
           )

    flush()
    backfill(repo())
  end

  def down do
    drop table(:signoff_requests)
  end

  @doc false
  def backfill(repo) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    held =
      repo.all(
        from(s in "playbook_steps",
          join: r in "playbook_runs",
          on: r.id == s.run_id,
          where: s.status == "awaiting_approval" and r.status == "awaiting_approval",
          select: %{
            step_pk: s.id,
            step_key: s.step_id,
            title: s.title,
            result: s.result,
            run_id: r.id,
            channel_id: r.channel_id,
            coordinator: r.coordinator_agent_id
          }
        )
      )

    carded =
      repo.all(
        from(c in "signoff_requests",
          where: c.status == "pending" and not is_nil(c.playbook_step_id),
          select: c.playbook_step_id
        )
      )
      |> MapSet.new()

    rows =
      held
      |> Enum.reject(&MapSet.member?(carded, &1.step_pk))
      |> Enum.map(fn h ->
        title = cut(one_line(h.title || h.step_key || "Sign-off"), 80)

        %{
          id: Canopy.ID.generate("so"),
          channel_id: h.channel_id,
          agent_id: h.coordinator,
          run_id: h.run_id,
          playbook_step_id: h.step_pk,
          step_id: h.step_key,
          title: title,
          question: cut(~s(Is "#{title}" done?), 300),
          summary: h.result,
          options: "[]",
          document_ids: "[]",
          status: "pending",
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [], do: repo.insert_all("signoff_requests", rows)
    length(rows)
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp cut(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
