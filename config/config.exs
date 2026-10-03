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
  "claude_code" => Canopy.Engine.ClaudeCode
}

# GitHub watches read GitHub through the user's `gh` CLI (Canopy.GitHub.CLI); the
# binary comes from Settings. Tests swap the client for a Mox double.
config :canopy, :github, []

# Claude Code runs as `claude -p` per turn. The binary and config dir come from
# Settings; this config only carries overrides (tests point `binary` at a fake).
config :canopy, :claude_code, []

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
