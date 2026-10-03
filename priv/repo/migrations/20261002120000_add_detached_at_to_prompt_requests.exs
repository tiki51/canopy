defmodule Canopy.Repo.Migrations.AddDetachedAtToPromptRequests do
  use Ecto.Migration

  # A permission or question card whose agent stopped waiting (its turn ended,
  # or the blocking wait ran out) stays answerable; the answer then wakes the
  # agent as a new message. `detached_at` marks that state.
  def change do
    alter table(:question_requests) do
      add :detached_at, :utc_datetime_usec
    end

    alter table(:permission_requests) do
      add :detached_at, :utc_datetime_usec
    end
  end
end
