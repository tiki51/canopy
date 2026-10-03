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
    # a global stop on agent activity (Canopy.Hold): why, and since when
    field :hold_reason, :string
    field :hold_at, :utc_datetime_usec
    # the agent the Costs page asks to review spend; nil until the user picks one
    field :auditor_agent_id, :string
    # overrides the collaboration preamble Canopy ships; nil/"" uses the default
    field :collaboration_prompt, :string
    # Claude Code: the binary (a name on PATH or a path), an optional config dir
    # for the agents' own login and transcripts, and a per-turn spend cap
    field :claude_binary, :string, default: "claude"
    field :claude_config_dir, :string
    field :claude_max_budget_usd, :float
    # GitHub watches run the user's `gh` CLI (a name on PATH or a path)
    field :gh_binary, :string, default: "gh"
    # the model (and, for Claude Code, the effort) an agent with none of its own
    # runs on, per engine; nil leaves the choice to the engine
    field :claude_default_model, :string
    field :claude_default_effort, :string
    field :opencode_default_provider, :string
    field :opencode_default_model, :string
    # model routing (experimental): the light model (and, for Claude Code, the
    # effort) a routed agent with none of its own runs cheap wakes on; nil: none
    field :claude_light_model, :string
    field :claude_light_effort, :string
    field :opencode_light_provider, :string
    field :opencode_light_model, :string
    # when first-run setup was finished or skipped; nil sends `/` to /welcome.
    # Set only by `Canopy.Settings.mark_onboarded/0`, never cast.
    field :onboarded_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

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
      :hold_reason,
      :hold_at,
      :auditor_agent_id,
      :collaboration_prompt,
      :claude_binary,
      :claude_config_dir,
      :claude_max_budget_usd,
      :gh_binary,
      :claude_default_model,
      :claude_default_effort,
      :opencode_default_provider,
      :opencode_default_model,
      :claude_light_model,
      :claude_light_effort,
      :opencode_light_provider,
      :opencode_light_model
    ])
    |> update_change(:claude_binary, &trim_or_nil/1)
    |> update_change(:gh_binary, &trim_or_nil/1)
    |> update_change(:claude_default_model, &trim_or_nil/1)
    |> update_change(:claude_default_effort, &trim_or_nil/1)
    |> update_change(:opencode_default_provider, &trim_or_nil/1)
    |> update_change(:opencode_default_model, &trim_or_nil/1)
    |> update_change(:claude_light_model, &trim_or_nil/1)
    |> update_change(:claude_light_effort, &trim_or_nil/1)
    |> update_change(:opencode_light_provider, &trim_or_nil/1)
    |> update_change(:opencode_light_model, &trim_or_nil/1)
    |> update_change(:claude_config_dir, &normalize_claude_config_dir/1)
    |> validate_required([
      :opencode_url,
      :user_display_name,
      :chatter_pause,
      :chatter_limit,
      :question_wait_minutes,
      :lock_hold_minutes,
      :claude_binary,
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
    |> validate_change(:claude_config_dir, fn :claude_config_dir, value ->
      if Path.type(value) == :absolute,
        do: [],
        else: [claude_config_dir: "must be an absolute path"]
    end)
    |> validate_url(:opencode_url)
    |> validate_inclusion(:claude_default_effort, Agent.efforts())
    |> validate_inclusion(:claude_light_effort, Agent.efforts())
    |> validate_default_models()
    |> validate_engine_models(
      {:claude_light_model, :opencode_light_provider, :opencode_light_model}
    )
  end

  # The same rules as an agent's own model: the alias list for Claude Code,
  # provider and model together for OpenCode. Checked only when a default
  # changes, so a stale one never blocks saving another setting.
  defp validate_default_models(changeset),
    do:
      validate_engine_models(
        changeset,
        {:claude_default_model, :opencode_default_provider, :opencode_default_model}
      )

  # One set of per-engine model columns (the defaults, or the light models).
  defp validate_engine_models(changeset, {claude_field, provider_field, model_field}) do
    claude =
      if changed?(changeset, claude_field) do
        Agent.model_errors("claude_code", nil, get_field(changeset, claude_field))
        |> Enum.map(fn {_field, message} -> {claude_field, message} end)
      else
        []
      end

    opencode =
      if changed?(changeset, provider_field) or changed?(changeset, model_field) do
        Agent.model_errors(
          "opencode",
          get_field(changeset, provider_field),
          get_field(changeset, model_field)
        )
        |> Enum.map(fn
          {:model_provider, message} -> {provider_field, message}
          {:model_id, message} -> {model_field, message}
        end)
      else
        []
      end

    Enum.reduce(claude ++ opencode, changeset, fn {field, message}, acc ->
      add_error(acc, field, message)
    end)
  end

  @doc "The longest a Claude Code question may wait: a minute under the MCP tool timeout."
  def max_question_wait_minutes, do: 29

  @doc "The longest a lock held across turns may be kept: a working day."
  def max_lock_hold_minutes, do: 480

  @doc "Trims a Claude config directory and expands a leading `~` using HOME."
  def normalize_claude_config_dir(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "~" -> System.user_home!()
      "~/" <> rest -> Path.join(System.user_home!(), rest)
      trimmed -> trimmed
    end
  end

  def normalize_claude_config_dir(value), do: value

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
