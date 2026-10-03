defmodule Canopy.Teams.TeamMember do
  @moduledoc "One agent on a team, with an optional role label on that team."

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :string

  schema "team_members" do
    belongs_to :team, Canopy.Teams.Team, primary_key: true
    belongs_to :agent, Canopy.Agents.Agent, primary_key: true
    # what the member does on this team ("reviewer"); playbooks will fill roles from it
    field :role, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
