defmodule Canopy.Settings.Setting do
  @moduledoc "The single application settings row (`id = \"default\"`)."

  use Ecto.Schema
  import Ecto.Changeset

  alias Canopy.Agents.Agent

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "settings" do
    field :opencode_url, :string, default: "http://127.0.0.1:4096"
    field :user_display_name, :string, default: "You"
    field :mcp_token, :string, redact: true
    field :plugin_verified_at, :utc_datetime_usec
    # pause agent-to-agent conversation after this many turns without the user
    field :chatter_pause, :boolean, default: true
    field :chatter_limit, :integer, default: 6
    # one agent turn at a time per channel; others wait in order
    field :serialize_turns, :boolean, default: true
    # a mention of a working agent reaches its turn at the next step (steering);
    # experimental and off until the engines' behaviour is verified live
    field :interrupt_on_mention, :boolean, default: false
    # how long a Claude Code agent's question blocks its turn before the agent
    # moves on and the answer arrives later as a new message
    field :question_wait_minutes, :integer, default: 10
    # the longest an agent may keep a lock it asked to hold across turns
    # before Canopy frees it (Canopy.Locks)
    field :lock_hold_minutes, :integer, default: 30
    # the agent the Costs page asks to review spend; nil until the user picks one
    field :auditor_agent_id, :string
    # overrides the collaboration preamble Canopy ships; nil/"" uses the default
    field :collaboration_prompt, :string
    # Claude Code: the binary (a name on PATH or a path), an optional config dir
    # for the agents' own login and transcripts, and a per-turn spend cap
    field :claude_binary, :string, default: "claude"
    field :claude_config_dir, :string
    field :claude_max_budget_usd, :float
    # Codex: the binary (a name on PATH or a path) and an optional config dir
    # (`CODEX_HOME`; nil is Codex's own `~/.codex`)
    field :codex_binary, :string, default: "codex"
    field :codex_config_dir, :string
    # GitHub watches run the user's `gh` CLI (a name on PATH or a path)
    field :gh_binary, :string, default: "gh"
    # the engine an agent with none of its own runs on (`Canopy.Settings.default_engine/1`);
    # nil: OpenCode, as before there was a default
    field :default_engine, :string
    # the model (and, for Claude Code and Codex, the effort) an agent with none
    # of its own runs on, per engine; nil leaves the choice to the engine
    field :claude_default_model, :string
    field :claude_default_effort, :string
    field :codex_default_model, :string
    field :codex_default_effort, :string
    field :opencode_default_provider, :string
    field :opencode_default_model, :string
    # model routing (experimental): the light model (and, for Claude Code and
    # Codex, the effort) a routed agent with none of its own runs cheap wakes
    # on; nil: none
    field :claude_light_model, :string
    field :claude_light_effort, :string
    field :codex_light_model, :string
    field :codex_light_effort, :string
    field :opencode_light_provider, :string
    field :opencode_light_model, :string
    # the model an engine's agents move to when it pauses at a usage limit
    # (`Canopy.Fallback`), as "<engine>:<model>"; nil: no fallback, they wait
    field :claude_fallback, :string
    field :codex_fallback, :string
    field :opencode_fallback, :string
    # when first-run setup was finished or skipped; nil sends `/` to /welcome.
    # Set only by `Canopy.Settings.mark_onboarded/0`, never cast.
    field :onboarded_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  # Per engine, its model columns as {provider, model} (nil: the engine has
  # no provider): the defaults, and the light models.
  @default_model_fields %{
    "claude_code" => {nil, :claude_default_model},
    "codex" => {nil, :codex_default_model},
    "opencode" => {:opencode_default_provider, :opencode_default_model}
  }
  @light_model_fields %{
    "claude_code" => {nil, :claude_light_model},
    "codex" => {nil, :codex_light_model},
    "opencode" => {:opencode_light_provider, :opencode_light_model}
  }

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :opencode_url,
      :user_display_name,
      :plugin_verified_at,
      :chatter_pause,
      :chatter_limit,
      :serialize_turns,
      :interrupt_on_mention,
      :question_wait_minutes,
      :lock_hold_minutes,
      :auditor_agent_id,
      :collaboration_prompt,
      :claude_binary,
      :claude_config_dir,
      :claude_max_budget_usd,
      :codex_binary,
      :codex_config_dir,
      :gh_binary,
      :default_engine,
      :claude_default_model,
      :claude_default_effort,
      :opencode_default_provider,
      :opencode_default_model,
      :claude_light_model,
      :claude_light_effort,
      :opencode_light_provider,
      :opencode_light_model,
      :codex_default_model,
      :codex_default_effort,
      :codex_light_model,
      :codex_light_effort,
      :claude_fallback,
      :codex_fallback,
      :opencode_fallback
    ])
    |> update_change(:claude_binary, &trim_or_nil/1)
    |> update_change(:codex_binary, &trim_or_nil/1)
    |> update_change(:gh_binary, &trim_or_nil/1)
    |> update_change(:default_engine, &trim_or_nil/1)
    |> update_change(:claude_default_model, &trim_or_nil/1)
    |> update_change(:claude_default_effort, &trim_or_nil/1)
    |> update_change(:opencode_default_provider, &trim_or_nil/1)
    |> update_change(:opencode_default_model, &trim_or_nil/1)
    |> update_change(:claude_light_model, &trim_or_nil/1)
    |> update_change(:claude_light_effort, &trim_or_nil/1)
    |> update_change(:opencode_light_provider, &trim_or_nil/1)
    |> update_change(:opencode_light_model, &trim_or_nil/1)
    |> update_change(:codex_default_model, &trim_or_nil/1)
    |> update_change(:codex_default_effort, &trim_or_nil/1)
    |> update_change(:codex_light_model, &trim_or_nil/1)
    |> update_change(:codex_light_effort, &trim_or_nil/1)
    |> update_change(:claude_fallback, &trim_or_nil/1)
    |> update_change(:codex_fallback, &trim_or_nil/1)
    |> update_change(:opencode_fallback, &trim_or_nil/1)
    |> update_change(:claude_config_dir, &normalize_config_dir/1)
    |> update_change(:codex_config_dir, &normalize_config_dir/1)
    |> validate_required([
      :opencode_url,
      :user_display_name,
      :chatter_pause,
      :chatter_limit,
      :question_wait_minutes,
      :lock_hold_minutes,
      :claude_binary,
      :codex_binary,
      :gh_binary
    ])
    |> validate_number(:claude_max_budget_usd, greater_than: 0)
    |> validate_number(:chatter_limit, greater_than_or_equal_to: 1, less_than_or_equal_to: 1000)
    # under the 30 minutes after which the Claude Code MCP tool call itself
    # gives up: at 30 the CLI's timeout would fire first
    |> validate_number(:question_wait_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: max_question_wait_minutes()
    )
    |> validate_number(:lock_hold_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: max_lock_hold_minutes()
    )
    |> validate_length(:user_display_name, max: 80)
    |> validate_length(:collaboration_prompt, max: 20_000)
    |> validate_absolute_path(:claude_config_dir)
    |> validate_absolute_path(:codex_config_dir)
    |> validate_url(:opencode_url)
    |> validate_inclusion(:default_engine, Canopy.Engine.names())
    |> validate_inclusion(:claude_default_effort, Agent.efforts("claude_code"))
    |> validate_inclusion(:claude_light_effort, Agent.efforts("claude_code"))
    |> validate_inclusion(:codex_default_effort, Agent.efforts("codex"))
    |> validate_inclusion(:codex_light_effort, Agent.efforts("codex"))
    |> validate_engine_models(@default_model_fields)
    |> validate_engine_models(@light_model_fields)
    |> validate_fallback(:claude_fallback)
    |> validate_fallback(:codex_fallback)
    |> validate_fallback(:opencode_fallback)
  end

  defp validate_fallback(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Canopy.Fallback.error(value) do
        nil -> []
        message -> [{field, message}]
      end
    end)
  end

  # The same rules as an agent's own model (`Agent.model_errors/3`): the
  # alias list for Claude Code, any id but a Claude alias for Codex, provider
  # and model together for OpenCode. Each engine's columns are checked only
  # when one of them changes, so a stale one never blocks saving another
  # setting.
  defp validate_engine_models(changeset, fields) do
    Enum.reduce(fields, changeset, fn {engine, {provider_field, model_field}}, acc ->
      if changed?(acc, model_field) or (provider_field && changed?(acc, provider_field)) do
        provider = provider_field && get_field(acc, provider_field)

        engine
        |> Agent.model_errors(provider, get_field(acc, model_field))
        |> Enum.reduce(acc, fn
          {:model_provider, message}, acc ->
            add_error(acc, provider_field || model_field, message)

          {:model_id, message}, acc ->
            add_error(acc, model_field, message)
        end)
      else
        acc
      end
    end)
  end

  defp validate_absolute_path(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Path.type(value) == :absolute,
        do: [],
        else: [{field, "must be an absolute path"}]
    end)
  end

  @doc "The longest a Claude Code question may wait: a minute under the MCP tool timeout."
  def max_question_wait_minutes, do: 29

  @doc "The longest a lock held across turns may be kept: a working day."
  def max_lock_hold_minutes, do: 480

  @doc """
  Trims an engine's config directory (Claude Code's or Codex's) and expands a
  leading `~` using HOME; blank is nil.
  """
  def normalize_config_dir(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "~" -> System.user_home!()
      "~/" <> rest -> Path.join(System.user_home!(), rest)
      trimmed -> trimmed
    end
  end

  def normalize_config_dir(value), do: value

  @doc "`normalize_config_dir/1`, under its older name."
  def normalize_claude_config_dir(value), do: normalize_config_dir(value)

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(value), do: value

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
