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
    # which execution engine runs this agent (see `Canopy.Engine`); nil
    # follows the default engine from Settings (`Canopy.Agents.effective_engine/2`)
    field :engine, :string
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
    # Model routing (experimental): cheap wakes run on the light model and
    # effort; nil inherits the engine's light default from Settings
    field :routing_enabled, :boolean, default: false
    field :light_model_provider, :string
    field :light_model_id, :string
    field :light_effort, :string

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
      :active,
      :routing_enabled,
      :light_model_provider,
      :light_model_id,
      :light_effort
    ])
    |> update_change(:name, &normalize_name/1)
    |> update_change(:group, &normalize_group/1)
    |> put_default_display_name()
    |> update_change(:engine, &blank_to_nil/1)
    |> sync_reach()
    |> validate_required([:name, :display_name, :opencode_agent, :permission_mode])
    |> validate_inclusion(:engine, Canopy.Engine.names())
    |> validate_inclusion(:permission_mode, @permission_modes)
    |> update_change(:effort, &blank_to_nil/1)
    |> validate_inclusion(:effort, @efforts)
    |> update_change(:light_effort, &blank_to_nil/1)
    |> validate_inclusion(:light_effort, @efforts)
    |> update_change(:allowed_tools, &blank_to_nil/1)
    |> drop_stale_models()
    |> validate_claude_code()
    |> validate_model()
    |> validate_light_model()
    |> validate_format(:name, @name_regex,
      message: "must be lowercase letters, digits, dashes or underscores"
    )
    |> validate_length(:name, max: 40)
    |> validate_length(:display_name, max: 80)
    |> validate_length(:role, max: 200)
    |> validate_length(:group, max: 40)
    |> Canopy.Teams.validate_name_free()
    |> unique_constraint(:name)
  end

  @doc """
  What the agent's session can do: `:plan` (read-only) or `:build` (edits
  files), or nil when the engine settings say nothing about it. Read for the
  agent's effective engine (its own, else the default). Accepts plain maps
  too, for prompt tests (no `engine` key reads as OpenCode).
  """
  def execution_mode(agent) do
    engine =
      case Map.get(agent, :engine, "opencode") do
        nil -> Canopy.Settings.default_engine()
        engine -> engine
      end

    case {engine, Map.get(agent, :opencode_agent), Map.get(agent, :permission_mode)} do
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

  # An agent on the default engine keeps its reach when the default changes:
  # making it read-only (or not) through one engine's field does the same
  # through the other's (OpenCode's `plan` agent, Claude Code's `plan`
  # permission mode). Only when one of the two changes; a change that names
  # both (a template, say) is taken as given.
  defp sync_reach(changeset) do
    agent = changeset.changes[:opencode_agent]
    permission = changeset.changes[:permission_mode]

    cond do
      not is_nil(get_field(changeset, :engine)) -> changeset
      agent && is_nil(permission) -> mirror_plan(changeset, agent, :permission_mode, "default")
      permission && is_nil(agent) -> mirror_plan(changeset, permission, :opencode_agent, "build")
      true -> changeset
    end
  end

  defp mirror_plan(changeset, "plan", field, _unplanned), do: put_change(changeset, field, "plan")

  defp mirror_plan(changeset, _value, field, unplanned) do
    if get_field(changeset, field) == "plan",
      do: put_change(changeset, field, unplanned),
      else: changeset
  end

  # The engine the changeset's model rules apply to: the agent's own, else
  # the default engine from Settings (read only when the agent has none).
  defp effective_engine(changeset),
    do: get_field(changeset, :engine) || Canopy.Settings.default_engine()

  # An agent on the default engine may hold a model left from the engine the
  # default was before (passed over meanwhile, see
  # `Canopy.Agents.effective_model/2`). Saving it drops that model, as
  # switching engine on the form does, rather than refusing the save over a
  # field the form no longer shows.
  defp drop_stale_models(changeset) do
    if is_nil(get_field(changeset, :engine)) do
      engine = effective_engine(changeset)

      changeset
      |> drop_stale(engine, :model_provider, :model_id)
      |> drop_stale(engine, :light_model_provider, :light_model_id)
    else
      changeset
    end
  end

  defp drop_stale(changeset, engine, provider_field, model_field) do
    if changed?(changeset, provider_field) or changed?(changeset, model_field) or
         model_fits?(
           engine,
           get_field(changeset, provider_field),
           get_field(changeset, model_field)
         ),
       do: changeset,
       else: changeset |> put_change(provider_field, nil) |> put_change(model_field, nil)
  end

  # A Claude Code agent names its permissions; a blank model or effort
  # inherits the default from Settings. Claude Code has no providers.
  defp validate_claude_code(changeset) do
    if effective_engine(changeset) == "claude_code" do
      changeset
      |> put_change(:model_provider, nil)
      |> put_change(:light_model_provider, nil)
      |> validate_required([:permission_mode])
    else
      changeset
    end
  end

  # Checked only when the model or the engine changes, so an older row that
  # breaks today's rules still saves its other fields.
  defp validate_model(changeset) do
    changeset =
      changeset
      |> update_change(:model_provider, &blank_to_nil/1)
      |> update_change(:model_id, &blank_to_nil/1)

    if Enum.any?([:engine, :model_provider, :model_id], &changed?(changeset, &1)) do
      changeset
      |> effective_engine()
      |> model_errors(get_field(changeset, :model_provider), get_field(changeset, :model_id))
      |> Enum.reduce(changeset, fn {field, message}, acc -> add_error(acc, field, message) end)
    else
      changeset
    end
  end

  # The light model follows the main model's rules (`model_errors/3`), checked
  # the same way: only when it or the engine changes.
  defp validate_light_model(changeset) do
    changeset =
      changeset
      |> update_change(:light_model_provider, &blank_to_nil/1)
      |> update_change(:light_model_id, &blank_to_nil/1)

    if Enum.any?([:engine, :light_model_provider, :light_model_id], &changed?(changeset, &1)) do
      changeset
      |> effective_engine()
      |> model_errors(
        get_field(changeset, :light_model_provider),
        get_field(changeset, :light_model_id)
      )
      |> Enum.reduce(changeset, fn
        {:model_provider, message}, acc -> add_error(acc, :light_model_provider, message)
        {:model_id, message}, acc -> add_error(acc, :light_model_id, message)
      end)
    else
      changeset
    end
  end

  @doc """
  What is wrong with a model choice for an engine, as `[{field, message}]`
  keyed `:model_provider` / `:model_id`; nil for both means "inherit". A
  Claude Code model is one of `claude_models/0`; an OpenCode model names both
  its provider and its id, or neither. Whether OpenCode actually offers the
  pair is checked against its live list by the UI.
  """
  def model_errors("claude_code", _provider, nil), do: []

  def model_errors("claude_code", _provider, model) do
    if model in @claude_models,
      do: [],
      else: [model_id: "must be one of #{Enum.join(@claude_models, ", ")}"]
  end

  def model_errors(_engine, nil, nil), do: []
  def model_errors(_engine, nil, _model), do: [model_provider: "pick a provider for this model"]
  def model_errors(_engine, provider, nil), do: [model_id: "pick a model from #{provider}"]
  def model_errors(_engine, _provider, _model), do: []

  @doc """
  Whether `engine` can run an agent's own model, or whether it was left from
  the other engine (when the default engine changed under an agent that
  follows it). Claude Code runs only its aliases; OpenCode runs anything
  but a bare Claude Code alias, so an older half-filled OpenCode row counts
  as before. No model always fits.
  """
  def model_fits?(_engine, _provider, nil), do: true
  def model_fits?("claude_code", _provider, model), do: model in @claude_models

  def model_fits?(_engine, provider, model),
    do: not (is_nil(provider) and model in @claude_models)

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
