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
    # pause agent-to-agent conversation after this many turns without the user
    field :chatter_pause, :boolean, default: true
    field :chatter_limit, :integer, default: 6
    # one agent turn at a time per channel; others wait in order
    field :serialize_turns, :boolean, default: true
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
      :hold_reason,
      :hold_at,
      :auditor_agent_id,
      :collaboration_prompt,
      :claude_binary,
      :claude_config_dir,
      :claude_max_budget_usd
    ])
    |> update_change(:claude_binary, &trim_or_nil/1)
    |> update_change(:claude_config_dir, &normalize_claude_config_dir/1)
    |> validate_required([
      :opencode_url,
      :user_display_name,
      :chatter_pause,
      :chatter_limit,
      :claude_binary
    ])
    |> validate_number(:claude_max_budget_usd, greater_than: 0)
    |> validate_number(:chatter_limit, greater_than_or_equal_to: 1, less_than_or_equal_to: 1000)
    |> validate_length(:user_display_name, max: 80)
    |> validate_length(:collaboration_prompt, max: 20_000)
    |> validate_change(:claude_config_dir, fn :claude_config_dir, value ->
      if Path.type(value) == :absolute,
        do: [],
        else: [claude_config_dir: "must be an absolute path"]
    end)
    |> validate_url(:opencode_url)
  end

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
