defmodule Canopy.Settings do
  @moduledoc """
  The single settings row. `get/0` creates it (and the MCP token) on first use.
  """

  alias Canopy.Repo
  alias Canopy.Settings.Setting
  alias Canopy.Users.User

  @id "default"

  @doc "Returns the settings row, creating it with defaults and a fresh token if needed."
  def get do
    case Repo.get(Setting, @id) do
      nil ->
        %Setting{id: @id, mcp_token: generate_token()}
        |> Setting.changeset(%{})
        |> Repo.insert!(on_conflict: :nothing)

        Repo.get!(Setting, @id)

      setting ->
        setting
    end
  end

  @doc """
  Updates the settings. A changed `user_display_name` is copied to the local
  user row so message attribution stays in sync.
  """
  def update(attrs) do
    changeset = Setting.changeset(get(), attrs)

    Repo.transaction(fn ->
      with {:ok, setting} <- Repo.update(changeset) do
        if Ecto.Changeset.changed?(changeset, :user_display_name) do
          Repo.update_all(User, set: [display_name: setting.user_display_name])
        end

        setting
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Replaces the MCP token. Callers must re-register the MCP entry with OpenCode."
  def rotate_mcp_token do
    result =
      get()
      |> Ecto.Changeset.change(mcp_token: generate_token())
      |> Repo.update()

    with {:ok, _} <- result do
      Phoenix.PubSub.broadcast(Canopy.PubSub, topic(), {:settings, :mcp_token_rotated})
    end

    result
  end

  @doc "PubSub topic for settings changes (`{:settings, :mcp_token_rotated}`)."
  def topic, do: "settings"
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, topic())

  @doc "Returns the current MCP token."
  def mcp_token, do: get().mcp_token

  @doc "Changeset for the settings form."
  def change(%Setting{} = setting, attrs \\ %{}), do: Setting.changeset(setting, attrs)

  defp generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
