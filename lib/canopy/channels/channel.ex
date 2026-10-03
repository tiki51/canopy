defmodule Canopy.Channels.Channel do
  @moduledoc "A collaboration channel bound to one repository, with one current owner."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["ch"]}}
  @foreign_key_type :string

  @statuses ~w(open archived)
  @kinds ~w(channel dm)
  @name_regex ~r/^[a-z0-9][a-z0-9_-]*$/

  @type t :: %__MODULE__{}

  schema "channels" do
    field :name, :string
    field :topic, :string
    field :status, :string, default: "open"
    field :kind, :string, default: "channel"
    # total dollars the channel may spend; nil for no limit. Only the user
    # changes it once set (see `Canopy.Channels.set_spend_limit/2`).
    field :spend_limit, :float
    # standing context every agent here gets in its system text; changed only
    # through `Canopy.Channels.set_brief/3` (see `brief_changeset/2`)
    field :brief, :string
    field :brief_updated_at, :utc_datetime_usec
    # "user" or an agent id
    field :brief_updated_by, :string

    belongs_to :repository, Canopy.Repositories.Repository
    belongs_to :owner, Canopy.Agents.Agent, foreign_key: :owner_agent_id
    has_one :task, Canopy.Tasks.Task
    has_many :channel_agents, Canopy.Channels.ChannelAgent

    many_to_many :agents, Canopy.Agents.Agent,
      join_through: Canopy.Channels.ChannelAgent,
      join_keys: [channel_id: :id, agent_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  @brief_max 4_000

  def statuses, do: @statuses
  def kinds, do: @kinds

  @doc "The most characters a brief may hold; it is never truncated."
  def brief_max, do: @brief_max

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :topic, :status, :kind, :repository_id, :owner_agent_id, :spend_limit])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name, :status, :repository_id])
    |> validate_format(:name, @name_regex,
      message: "must be lowercase letters, digits, dashes or underscores"
    )
    |> validate_length(:name, max: 60)
    |> validate_length(:topic, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:spend_limit, greater_than: 0, less_than: 1_000_000)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:owner_agent_id)
    |> unique_constraint([:repository_id, :name], error_key: :name)
  end

  @doc """
  The brief alone: trimmed, blank as nil, at most #{@brief_max} characters.
  `brief` is not in `changeset/2`, so nothing changes it without an event.
  """
  def brief_changeset(channel, attrs) do
    channel
    |> cast(attrs, [:brief], empty_values: [])
    |> update_change(:brief, &normalize_brief/1)
    |> validate_length(:brief, max: @brief_max)
  end

  defp normalize_brief(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_brief(other), do: other

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> String.trim_leading("#") |> String.downcase()
  end

  defp normalize_name(other), do: other
end
