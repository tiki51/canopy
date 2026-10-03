defmodule Canopy.Settings do
  @moduledoc """
  The single settings row. `get/0` creates it (and the MCP token) on first use.
  """

  alias Canopy.Repo
  alias Canopy.Settings.Setting
  alias Canopy.Users.User

  @id "default"

  # Per engine, the columns holding its default model as {provider, model}
  # (Claude Code has no provider), and its default effort where it has one.
  @model_fields %{
    "claude_code" => {nil, :claude_default_model},
    "opencode" => {:opencode_default_provider, :opencode_default_model}
  }
  @effort_fields %{"claude_code" => :claude_default_effort}
  @default_fields [
    :claude_default_model,
    :claude_default_effort,
    :opencode_default_provider,
    :opencode_default_model
  ]
  # The same, for the light model routed agents run cheap wakes on.
  @light_model_fields %{
    "claude_code" => {nil, :claude_light_model},
    "opencode" => {:opencode_light_provider, :opencode_light_model}
  }
  @light_effort_fields %{"claude_code" => :claude_light_effort}
  @light_fields [
    :claude_light_model,
    :claude_light_effort,
    :opencode_light_provider,
    :opencode_light_model
  ]

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
  user row so message attribution stays in sync; a changed default model or
  effort is broadcast as `{:settings, :default_models_changed}`, a changed
  light model or effort as `{:settings, :light_profiles_changed}`.
  """
  def update(attrs) do
    changeset = Setting.changeset(get(), attrs)

    result =
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

    with {:ok, _} <- result do
      if Enum.any?(@default_fields, &Ecto.Changeset.changed?(changeset, &1)),
        do: broadcast_defaults_changed()

      if Enum.any?(@light_fields, &Ecto.Changeset.changed?(changeset, &1)),
        do: Phoenix.PubSub.broadcast(Canopy.PubSub, topic(), {:settings, :light_profiles_changed})
    end

    result
  end

  @doc """
  Tells the pages that show default models that a default, or which agents
  inherit one, changed. Agents re-read their model every turn, so the runtime
  needs nothing.
  """
  def broadcast_defaults_changed,
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, topic(), {:settings, :default_models_changed})

  # -- Default models -----------------------------------------------------------

  @doc """
  The model an agent of `engine` with no model of its own runs on, as
  `%{model_provider: p, model_id: m}`. Claude Code has no provider; both nil
  means the engine picks (Claude Code's or OpenCode's own default).
  """
  def default_model(engine, setting \\ nil) when is_binary(engine) do
    setting = setting || get()

    case Map.fetch(@model_fields, engine) do
      {:ok, {provider, model}} ->
        %{
          model_provider: provider && Map.get(setting, provider),
          model_id: Map.get(setting, model)
        }

      :error ->
        %{model_provider: nil, model_id: nil}
    end
  end

  @doc "`default_model/1` for every engine, keyed by engine name."
  def default_models do
    setting = get()
    Map.new(Canopy.Engine.names(), &{&1, default_model(&1, setting)})
  end

  @doc """
  Sets an engine's default model from `%{model_provider: p, model_id: m}`
  (nils clear it; Claude Code ignores the provider). Validated like an
  agent's own model; whether OpenCode offers the pair is the caller's check.
  """
  def put_default_model(engine, attrs) when is_binary(engine) and is_map(attrs) do
    case Map.fetch(@model_fields, engine) do
      {:ok, {nil, model}} ->
        update(%{model => fetch_attr(attrs, :model_id)})

      {:ok, {provider, model}} ->
        update(%{
          provider => fetch_attr(attrs, :model_provider),
          model => fetch_attr(attrs, :model_id)
        })

      :error ->
        unsupported(engine, :model_id, "has no default model")
    end
  end

  @doc """
  The effort an agent of `engine` with no effort of its own runs at; nil when
  the engine picks, or has no effort setting (OpenCode).
  """
  def default_effort(engine, setting \\ nil) when is_binary(engine) do
    case Map.fetch(@effort_fields, engine) do
      {:ok, field} -> Map.get(setting || get(), field)
      :error -> nil
    end
  end

  @doc "`default_effort/1` for every engine, keyed by engine name."
  def default_efforts do
    setting = get()
    Map.new(Canopy.Engine.names(), &{&1, default_effort(&1, setting)})
  end

  @doc "Sets an engine's default effort (one of `Agent.efforts/0`, or nil to clear it)."
  def put_default_effort(engine, effort) when is_binary(engine) do
    case Map.fetch(@effort_fields, engine) do
      {:ok, field} -> update(%{field => effort})
      :error -> unsupported(engine, :effort, "has no effort setting")
    end
  end

  # -- Light models (model routing, experimental) -------------------------------

  @doc """
  The light profile a routed agent of `engine` with no light model of its own
  runs cheap wakes on, as `%{model_provider, model_id, effort}`; all nil when
  none is set. Claude Code has no provider, OpenCode no effort.
  """
  def light_profile(engine, setting \\ nil) when is_binary(engine) do
    setting = setting || get()

    {provider, model} = Map.get(@light_model_fields, engine, {nil, nil})
    effort = Map.get(@light_effort_fields, engine)

    %{
      model_provider: provider && Map.get(setting, provider),
      model_id: model && Map.get(setting, model),
      effort: effort && Map.get(setting, effort)
    }
  end

  @doc "`light_profile/1` for every engine, keyed by engine name."
  def light_profiles do
    setting = get()
    Map.new(Canopy.Engine.names(), &{&1, light_profile(&1, setting)})
  end

  @doc """
  Sets an engine's light profile from `%{model_provider, model_id, effort}`
  (nils clear; keys left out are left alone; Claude Code ignores the
  provider, OpenCode the effort). Validated like the default model.
  Broadcasts `{:settings, :light_profiles_changed}`.
  """
  def put_light_profile(engine, attrs) when is_binary(engine) and is_map(attrs) do
    case Map.fetch(@light_model_fields, engine) do
      {:ok, {provider, model}} ->
        effort = Map.get(@light_effort_fields, engine)

        [
          {provider, :model_provider},
          {model, :model_id},
          {effort, :effort}
        ]
        |> Enum.flat_map(fn
          {nil, _key} ->
            []

          {field, key} ->
            if has_attr?(attrs, key), do: [{field, fetch_attr(attrs, key)}], else: []
        end)
        |> Map.new()
        |> update()

      :error ->
        unsupported(engine, :model_id, "has no light model")
    end
  end

  defp has_attr?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  defp fetch_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp unsupported(engine, field, message) do
    {:error,
     get()
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(field, "#{engine} #{message}")}
  end

  # -- First-run setup ----------------------------------------------------------

  @doc "Whether first-run setup (`/welcome`) has been finished or skipped."
  def onboarded?, do: not is_nil(get().onboarded_at)

  @doc """
  Records that setup was finished or skipped, so `/` stops sending the user to
  `/welcome`. Running setup again stamps it again.
  """
  def mark_onboarded do
    get()
    |> Ecto.Changeset.change(onboarded_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc "Whether the user has replaced the default display name (\"You\")."
  def user_named?, do: get().user_display_name not in [nil, "", "You"]

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

  @doc """
  PubSub topic for settings changes: `{:settings, :mcp_token_rotated}`,
  `{:settings, :default_models_changed}`, and `{:settings, :light_profiles_changed}`.
  """
  def topic, do: "settings"
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, topic())

  @doc "Returns the current MCP token."
  def mcp_token, do: get().mcp_token

  @doc "Whether a channel runs one agent turn at a time (others queue) or lets agents run in parallel."
  def serialize_turns?, do: get().serialize_turns

  @doc """
  Whether a user's mention of a working agent reaches its turn at the next
  step rather than after the turn (Agent Interrupt). Experimental: off by
  default until the engines' behaviour is verified live.
  """
  def interrupt_on_mention?, do: get().interrupt_on_mention == true

  @doc "How long a Claude Code question blocks its turn before going async, in milliseconds."
  def question_wait_ms, do: :timer.minutes(get().question_wait_minutes || 10)

  @doc "How long an agent may keep a lock held across turns before Canopy frees it, in milliseconds."
  def lock_hold_ms, do: :timer.minutes(get().lock_hold_minutes || 30)

  @doc """
  How many agent turns a channel allows between user messages before pausing,
  or nil when pausing is turned off.
  """
  def chatter_limit do
    case get() do
      %Setting{chatter_pause: true, chatter_limit: n} when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc "Changeset for the settings form."
  def change(%Setting{} = setting, attrs \\ %{}), do: Setting.changeset(setting, attrs)

  defp generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
