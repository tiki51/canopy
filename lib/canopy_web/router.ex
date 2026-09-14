defmodule CanopyWeb.Router do
  use CanopyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CanopyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The Canopy MCP endpoint: no session or CSRF, bearer token from settings.
  # The Anubis plug enforces the JSON/SSE accept headers itself; agent identity
  # is resolved inside the tools, not here.
  pipeline :mcp do
    plug Canopy.MCP.AuthPlug
  end

  scope "/", CanopyWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :default, on_mount: [CanopyWeb.Nav] do
      live "/settings", SettingsLive
      live "/costs", CostsLive
      live "/files", FilesLive
      live "/repositories", RepositoriesLive
      live "/agents", AgentsLive, :index
      live "/agents/new", AgentsLive, :new
      live "/agents/:id", AgentsLive, :show
      live "/agents/:id/edit", AgentsLive, :edit
      live "/channels/new", ChannelLive.New
      live "/channels/:id", ChannelLive
    end

    get "/dm/:agent_id", DmController, :show
    get "/files/:id/:filename", FileController, :show
  end

  scope "/mcp" do
    pipe_through :mcp

    # A Claude Code permission prompt blocks its tool call until the user answers,
    # so requests may stay open as long as `Canopy.ClaudeCode.Prompts` waits.
    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: Canopy.MCP.Server,
      request_timeout: Canopy.ClaudeCode.Prompts.timeout_ms() + :timer.minutes(1)
  end

  # Other scopes may use custom stacks.
  # scope "/api", CanopyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:canopy, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CanopyWeb.Telemetry
    end
  end
end
