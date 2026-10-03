defmodule Canopy.Teams.Team do
  @moduledoc """
  A named crew of agents, addressable as `@name` like an agent. Membership is
  many-to-many and crosses groups; every team has a lead, who must be a member.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Canopy.Agents.Agent

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["tm"]}}
  @foreign_key_type :string

  # the same slug rules as agent names: both are `@name`
  @name_regex ~r/^[a-z0-9][a-z0-9_-]*$/

  @type t :: %__MODULE__{}

  schema "teams" do
    field :name, :string
    field :display_name, :string
    field :description, :string

    belongs_to :lead, Agent, foreign_key: :lead_agent_id
    has_many :memberships, Canopy.Teams.TeamMember
    many_to_many :members, Agent, join_through: Canopy.Teams.TeamMember

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a team. `member_ids` is the member set being saved: it may not be
  empty, and the lead must be in it. A lead dropped from the members is an
  error rather than a silent change: the user picks the new lead first.
  """
  def changeset(team, attrs, member_ids) do
    team
    |> cast(attrs, [:name, :display_name, :description, :lead_agent_id])
    |> update_change(:name, &normalize_name/1)
    |> update_change(:display_name, &blank_to_nil/1)
    |> update_change(:description, &blank_to_nil/1)
    |> put_default_display_name()
    |> validate_required([:name, :display_name])
    |> validate_required([:lead_agent_id], message: "pick a lead")
    |> validate_format(:name, @name_regex,
      message: "must be lowercase letters, digits, dashes or underscores"
    )
    |> validate_length(:name, max: 40)
    |> validate_length(:display_name, max: 80)
    |> validate_length(:description, max: 200)
    |> validate_members(member_ids)
    |> Canopy.Teams.validate_name_free()
    |> unique_constraint(:name)
  end

  defp validate_members(changeset, []),
    do: add_error(changeset, :agent_ids, "pick at least one member")

  defp validate_members(changeset, member_ids) do
    lead = get_field(changeset, :lead_agent_id)

    if is_nil(lead) or lead in member_ids do
      changeset
    else
      add_error(changeset, :lead_agent_id, "choose a new lead before removing the current one")
    end
  end

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> String.trim_leading("@") |> String.downcase()
  end

  defp normalize_name(other), do: other

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp put_default_display_name(changeset) do
    case {get_field(changeset, :display_name), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) -> put_change(changeset, :display_name, name)
      _ -> changeset
    end
  end
end
