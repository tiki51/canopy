import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :canopy, Canopy.Repo,
  database: Path.expand("../canopy_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# Document bytes for tests go under _build so they never mix with dev files.
config :canopy, files_dir: Path.expand("../_build/test/tmp/files", __DIR__)

# Tests index documents themselves (Canopy.Search.Backfill.run/0); the boot task
# would race the sandbox.
config :canopy, :search_backfill, false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :canopy, CanopyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/MtOdacxgtug40rj9U5jDzZJdMgmDMIhQqUl60dOgK/3QdtQ5uwxw+UrYw6Ug1Vn",
  server: false

# Phoenix.ConnTest addresses every request to www.example.com.
config :canopy, extra_hosts: ["www.example.com"]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The runtime talks to a Mox double in tests; the real client is exercised with Req.Test.
config :canopy, Oban, testing: :manual

# Claude Code turns spawn a script that prints canned stream-json (see test/support/fake_claude.sh).
# Transcripts are read from fixtures, never the real ~/.claude (tests that read one
# point `config_dir` at test/support/claude_code_fixtures/transcripts).
config :canopy, :claude_code,
  binary: Path.expand("../test/support/fake_claude.sh", __DIR__),
  default_config_dir: Path.expand("../test/support/claude_code_fixtures/none", __DIR__)

# The repository page's MCP inventory reads config files from fixtures, never
# the real home (see Canopy.MCP.Inventory).
config :canopy, :mcp_inventory,
  home: Path.expand("../test/support/mcp_fixtures/claude/home", __DIR__),
  managed_path: Path.expand("../test/support/mcp_fixtures/none/managed-mcp.json", __DIR__),
  config_home: Path.expand("../test/support/mcp_fixtures/opencode/global", __DIR__),
  opencode_config: nil

# First-run setup prefills the display name from `git config --global user.name`;
# tests answer for git instead of shelling out (see CanopyWeb.OnboardingLive).
config :canopy, :git_user_name, ""

config :canopy, :opencode,
  base_url: "http://opencode.test",
  client: Canopy.OpenCode.ClientMock,
  req_options: [plug: {Req.Test, Canopy.OpenCode.Client}],
  start_streams: false

# GitHub watches talk to a Mox double; Canopy.GitHub.CLI's own tests run the
# fake `gh` (test/support/fake_gh.sh), never the real one.
config :canopy, :github,
  client: Canopy.GitHub.Mock,
  binary: Path.expand("../test/support/fake_gh.sh", __DIR__)

# A channel that goes quiet says so at once (Canopy.Runtime.ChannelServer's
# quiet check), so tests assert on the signal without waiting.
config :canopy, :quiet_ms, 0
