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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :canopy, CanopyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/MtOdacxgtug40rj9U5jDzZJdMgmDMIhQqUl60dOgK/3QdtQ5uwxw+UrYw6Ug1Vn",
  server: false

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

config :canopy, :opencode,
  base_url: "http://opencode.test",
  client: Canopy.OpenCode.ClientMock,
  req_options: [plug: {Req.Test, Canopy.OpenCode.Client}],
  start_streams: false
