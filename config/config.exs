# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :canopy,
  ecto_repos: [Canopy.Repo],
  generators: [timestamp_type: :utc_datetime],
  public_url: nil

# OpenCode integration defaults. The runtime overrides base_url from Settings.
# Oban runs scheduled agent tasks (see Canopy.Schedules), playbook stall checks,
# and the GitHub watch sweep. SQLite via the Lite engine.
config :canopy, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  repo: Canopy.Repo,
  queues: [schedules: 3, watches: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    # GitHub watches are rows, not jobs: one sweep a minute checks those due
    {Oban.Cron, crontab: [{"* * * * *", Canopy.Watches.SweepWorker}]}
  ]

config :canopy, :opencode,
  base_url: "http://127.0.0.1:4096",
  client: Canopy.OpenCode.Client

# Execution engines by name, as stored on agents and sessions.
config :canopy, :engines, %{
  "opencode" => Canopy.Engine.OpenCode,
  "claude_code" => Canopy.Engine.ClaudeCode,
  "codex" => Canopy.Engine.Codex
}

# GitHub watches read GitHub through the user's `gh` CLI (Canopy.GitHub.CLI); the
# binary comes from Settings. Tests swap the client for a Mox double.
config :canopy, :github, []

# Claude Code runs as `claude -p` per turn. The binary and config dir come from
# Settings; this config only carries overrides (tests point `binary` at a fake).
config :canopy, :claude_code, []

# Codex runs as `codex app-server` per turn. The binary and config dir come from
# Settings; this config only carries overrides (tests point `binary` at a fake).
config :canopy, :codex, []

# Model routing (experimental, off until the Phase 0 spike). How long a
# provider's prompt cache is taken to stay warm (the cache-warmth guard), and
# Claude list prices per million tokens for the routing estimates only (Claude
# Code's real costs stay the CLI's total_cost_usd). Prices from the claude-api
# reference, 2026-06; a cache write is the 5-minute write, 1.25x input.
config :canopy, :routing_cache_ttl_ms, 300_000

config :canopy, :claude_list_prices, %{
  "haiku" => %{input: 1.0, output: 5.0, cache_read: 0.10, cache_write: 1.25},
  "sonnet" => %{input: 2.0, output: 10.0, cache_read: 0.20, cache_write: 2.5},
  "opus" => %{input: 4.0, output: 20.0, cache_read: 0.20, cache_write: 5.0},
  "fable" => %{input: 10.0, output: 50.0, cache_read: 0.25, cache_write: 12.5}
}

# Codex reports tokens, not dollars: its turn costs are estimates (shown with
# ≈) from these OpenAI API list prices, USD per million tokens, from the
# OpenAI API pricing page (developers.openai.com/api/docs/pricing), checked
# 2026-10-19. A key is a model id or an id prefix (a dated snapshot like
# gpt-5-2025-08-07 takes gpt-5's price); a model matching none takes
# "default", the flagship Codex price (see Canopy.Codex.Pricing). Cache
# writes are priced as input. gpt-6 and gpt-5.6 roughly double their input
# price above 272K input tokens, which this table doesn't model. The older
# rows are retired models, kept for past turns. A ChatGPT plan is not billed
# per token.
config :canopy, :codex_list_prices, %{
  "gpt-6-astra" => %{input: 10.0, cached_input: 1.0, output: 50.0},
  "gpt-6.1-sol" => %{input: 2.0, cached_input: 0.10, output: 10.0},
  "gpt-6-sol" => %{input: 2.0, cached_input: 0.20, output: 10.0},
  "gpt-6-luna" => %{input: 0.10, cached_input: 0.01, output: 0.50},
  # promotional price "through at least 2026-11-21"
  "gpt-5.6-sol" => %{input: 4.0, cached_input: 0.40, output: 20.0},
  "gpt-5.6-terra" => %{input: 2.0, cached_input: 0.20, output: 12.0},
  "gpt-5.6-luna" => %{input: 0.20, cached_input: 0.02, output: 1.20},
  "gpt-5.5" => %{input: 5.0, cached_input: 0.50, output: 30.0},
  "gpt-5.4" => %{input: 2.50, cached_input: 0.25, output: 15.0},
  "gpt-5.4-mini" => %{input: 0.75, cached_input: 0.075, output: 4.50},
  "gpt-5.3-codex" => %{input: 1.75, cached_input: 0.175, output: 14.0},
  "gpt-5" => %{input: 1.25, cached_input: 0.125, output: 10.0},
  "gpt-5-codex" => %{input: 1.25, cached_input: 0.125, output: 10.0},
  "gpt-5-mini" => %{input: 0.25, cached_input: 0.025, output: 2.0},
  "gpt-5-nano" => %{input: 0.05, cached_input: 0.005, output: 0.4},
  "gpt-5-pro" => %{input: 15.0, cached_input: 15.0, output: 120.0},
  "gpt-5.1" => %{input: 1.25, cached_input: 0.125, output: 10.0},
  "gpt-5.1-codex" => %{input: 1.25, cached_input: 0.125, output: 10.0},
  "gpt-5.1-codex-max" => %{input: 1.25, cached_input: 0.125, output: 10.0},
  "gpt-5.1-codex-mini" => %{input: 0.25, cached_input: 0.025, output: 2.0},
  "gpt-5.2" => %{input: 1.75, cached_input: 0.175, output: 14.0},
  "gpt-5.2-codex" => %{input: 1.75, cached_input: 0.175, output: 14.0},
  "codex-mini-latest" => %{input: 1.5, cached_input: 0.375, output: 6.0},
  # gpt-6.1-sol
  "default" => %{input: 2.0, cached_input: 0.10, output: 10.0}
}

# Configure the endpoint
config :canopy, CanopyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CanopyWeb.ErrorHTML, json: CanopyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Canopy.PubSub,
  live_view: [signing_salt: "LaDmXasG"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  canopy: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  canopy: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
