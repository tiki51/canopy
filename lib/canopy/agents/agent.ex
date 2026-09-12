defmodule Canopy.Agents.Agent do
  @moduledoc "A named Canopy coworker backed by an OpenCode agent and a role prompt."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["agt"]}}
  @foreign_key_type :string

  @name_regex ~r/^[a-z0-9][a-z0-9_-]*$/

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :display_name, :string
    field :role, :string
    # optional label the sidebar and pickers group agents under ("Engineering")
    field :group, :string
    field :system_prompt, :string
    field :opencode_agent, :string, default: "build"
    field :model_provider, :string
    field :model_id, :string
    field :color, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :display_name,
      :role,
      :group,
      :system_prompt,
      :opencode_agent,
      :model_provider,
      :model_id,
      :color,
      :active
    ])
    |> update_change(:name, &normalize_name/1)
    |> update_change(:group, &normalize_group/1)
    |> put_default_display_name()
    |> validate_required([:name, :display_name, :opencode_agent])
    |> validate_format(:name, @name_regex,
      message: "must be lowercase letters, digits, dashes or underscores"
    )
    |> validate_length(:name, max: 40)
    |> validate_length(:display_name, max: 80)
    |> validate_length(:role, max: 200)
    |> validate_length(:group, max: 40)
    |> unique_constraint(:name)
  end

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> String.trim_leading("@") |> String.downcase()
  end

  defp normalize_name(other), do: other

  defp normalize_group(group) when is_binary(group) do
    case String.trim(group) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_group(other), do: other

  defp put_default_display_name(changeset) do
    case {get_field(changeset, :display_name), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) -> put_change(changeset, :display_name, name)
      _ -> changeset
    end
  end
end
