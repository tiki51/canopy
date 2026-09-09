defmodule Canopy.Settings.Setting do
  @moduledoc "The single application settings row (`id = \"default\"`)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "settings" do
    field :opencode_url, :string, default: "http://127.0.0.1:4096"
    field :user_display_name, :string, default: "You"
    field :mcp_token, :string, redact: true
    field :plugin_verified_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:opencode_url, :user_display_name, :plugin_verified_at])
    |> validate_required([:opencode_url, :user_display_name])
    |> validate_length(:user_display_name, max: 80)
    |> validate_url(:opencode_url)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be an http or https URL"}]
      end
    end)
  end
end
