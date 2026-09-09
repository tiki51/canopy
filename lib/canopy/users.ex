defmodule Canopy.Users do
  @moduledoc "The single local user (v0 has no authentication)."

  import Ecto.Query, warn: false

  alias Canopy.Repo
  alias Canopy.Settings
  alias Canopy.Users.User

  @doc "Returns the local user, creating it from the settings display name on first call."
  def local do
    case Repo.one(from u in User, order_by: [asc: u.id], limit: 1) do
      nil ->
        %User{}
        |> User.changeset(%{display_name: Settings.get().user_display_name})
        |> Repo.insert!()

      user ->
        user
    end
  end

  def get!(id), do: Repo.get!(User, id)
end
