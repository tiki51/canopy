defmodule Canopy.Repositories.Repository do
  @moduledoc "A local git repository that channels are attached to."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["repo"]}}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "repositories" do
    field :name, :string
    field :path, :string

    has_many :channels, Canopy.Channels.Channel

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [:name, :path])
    |> update_change(:path, &expand_path/1)
    |> put_default_name()
    |> validate_required([:name, :path])
    |> validate_length(:name, max: 120)
    |> unique_constraint(:path)
  end

  defp expand_path(path) when is_binary(path) do
    path = String.trim(path)

    case path do
      "/" <> _ -> Path.expand(path)
      "~" <> _ -> Path.expand(path)
      _ -> path
    end
  end

  defp expand_path(other), do: other

  defp put_default_name(changeset) do
    case {get_field(changeset, :name), get_field(changeset, :path)} do
      {nil, path} when is_binary(path) -> put_change(changeset, :name, Path.basename(path))
      _ -> changeset
    end
  end
end
