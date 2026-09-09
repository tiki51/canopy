defmodule Canopy.Users.User do
  @moduledoc "The single local user. Kept as a table so `messages.user_id` is a real FK."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["usr"]}}
  @foreign_key_type :string

  schema "users" do
    field :display_name, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name])
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: 80)
  end
end
