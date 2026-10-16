defmodule Canopy.Channels.Section do
  @moduledoc """
  A named group of a project's channels in the sidebar. Names are unique per
  repository whatever their (ASCII) case; `position` is 0-based and kept
  contiguous by `Canopy.Channels.Sections`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["sec"]}}
  @foreign_key_type :string

  @name_max 40

  @type t :: %__MODULE__{}

  schema "channel_sections" do
    field :name, :string
    field :position, :integer, default: 0
    field :collapsed, :boolean, default: false
    # true only on the struct `Sections.find_or_create/2` returns when it inserted
    field :created?, :boolean, virtual: true, default: false

    belongs_to :repository, Canopy.Repositories.Repository
    has_many :channels, Canopy.Channels.Channel

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The most characters a section name may hold."
  def name_max, do: @name_max

  def changeset(section, attrs) do
    section
    |> cast(attrs, [:repository_id, :name, :position, :collapsed])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:repository_id, :name])
    |> validate_name()
    |> foreign_key_constraint(:repository_id)
    |> unique_constraint([:repository_id, :name],
      error_key: :name,
      message: "is already a section in this project"
    )
  end

  def name_changeset(section, attrs) do
    section
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name])
    |> validate_name()
    |> unique_constraint([:repository_id, :name],
      error_key: :name,
      message: "is already a section in this project"
    )
  end

  @doc "The trimmed name; blank comes back as nil."
  def normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_name(other), do: other

  defp validate_name(changeset) do
    changeset
    |> validate_length(:name, max: @name_max)
    |> validate_format(:name, ~r/\A[^\r\n]*\z/, message: "must be on one line")
  end
end
