defmodule Canopy.Agents.Agent do
  @moduledoc "A named Canopy coworker: an execution engine, the engine's agent or model settings, and a role prompt."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: {Canopy.ID, :generate, ["agt"]}}
  @foreign_key_type :string

  @name_regex ~r/^[a-z0-9][a-z0-9_-]*$/

  # Claude Code permission modes Canopy offers: prompts for everything not
  # allowed, auto-approves edits, or read-only planning. Never bypass.
  @permission_modes ~w(default acceptEdits plan)
  @efforts ~w(low medium high xhigh max)
  # the aliases Claude Code resolves to the latest model of each family
  @claude_models ~w(fable opus sonnet haiku)

  def permission_modes, do: @permission_modes
  def efforts, do: @efforts
  def claude_models, do: @claude_models

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :display_name, :string
    field :role, :string
    # optional label the sidebar and pickers group agents under ("Engineering")
    field :group, :string
    field :system_prompt, :string
    # which execution engine runs this agent (see `Canopy.Engine`)
    field :engine, :string, default: "opencode"
    field :opencode_agent, :string, default: "build"
    field :model_provider, :string
    field :model_id, :string
    # Claude Code: how tool calls are approved, the effort level, and the
    # tools that run without asking (one pattern per line; blank = the default set)
    field :permission_mode, :string, default: "default"
    field :effort, :string
    field :allowed_tools, :string
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
      :engine,
      :opencode_agent,
      :model_provider,
      :model_id,
      :permission_mode,
      :effort,
      :allowed_tools,
      :color,
      :active
    ])
    |> update_change(:name, &normalize_name/1)
    |> update_change(:group, &normalize_group/1)
    |> put_default_display_name()
    |> validate_required([:name, :display_name, :engine, :opencode_agent, :permission_mode])
    |> validate_inclusion(:engine, Canopy.Engine.names())
    |> validate_inclusion(:permission_mode, @permission_modes)
    |> update_change(:effort, &blank_to_nil/1)
    |> validate_inclusion(:effort, @efforts)
    |> update_change(:allowed_tools, &blank_to_nil/1)
    |> validate_claude_code()
    |> validate_format(:name, @name_regex,
      message: "must be lowercase letters, digits, dashes or underscores"
    )
    |> validate_length(:name, max: 40)
    |> validate_length(:display_name, max: 80)
    |> validate_length(:role, max: 200)
    |> validate_length(:group, max: 40)
    |> unique_constraint(:name)
  end

  @doc """
  What the agent's session can do: `:plan` (read-only) or `:build` (edits
  files), or nil when the engine settings say nothing about it. Accepts plain
  maps too, for prompt tests.
  """
  def execution_mode(agent) do
    case {Map.get(agent, :engine, "opencode"), Map.get(agent, :opencode_agent),
          Map.get(agent, :permission_mode)} do
      {"opencode", "plan", _} -> :plan
      {"opencode", "build", _} -> :build
      {"claude_code", _, "plan"} -> :plan
      {"claude_code", _, _} -> :build
      _ -> nil
    end
  end

  @doc "The tool patterns a Claude Code agent may run unasked: one per line or comma."
  def allowed_tools_list(%{allowed_tools: text}) when is_binary(text) do
    text
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def allowed_tools_list(_agent), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # A Claude Code agent always names its model alias, effort, and permissions.
  defp validate_claude_code(changeset) do
    if get_field(changeset, :engine) == "claude_code" do
      changeset
      |> validate_required([:model_id, :effort, :permission_mode])
      |> validate_inclusion(:model_id, @claude_models,
        message: "must be one of #{Enum.join(@claude_models, ", ")}"
      )
    else
      changeset
    end
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
