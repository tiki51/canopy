defmodule Canopy.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      CanopyWeb.Telemetry,
      Canopy.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:canopy, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:canopy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Canopy.PubSub},
      # Durable jobs: scheduled agent tasks
      {Oban, Application.fetch_env!(:canopy, Oban)},
      # Per-repository SSE subscriptions to the OpenCode server
      Canopy.OpenCode.Supervisor,
      # One `claude -p` process per Claude Code turn, and the prompts they wait on
      Canopy.ClaudeCode.Supervisor,
      Canopy.ClaudeCode.Prompts,
      # One process per open channel owning agent sessions
      Canopy.Runtime.Supervisor,
      # MCP server for agents (Streamable HTTP, mounted at /mcp; transport starts only when the endpoint serves)
      {Canopy.MCP.Server, transport: :streamable_http},
      # Start a worker by calling: Canopy.Worker.start_link(arg)
      # {Canopy.Worker, arg},
      # Start to serve requests, typically the last entry
      CanopyWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Canopy.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if Phoenix.Endpoint.server?(:canopy, CanopyWeb.Endpoint), do: release_locks()
      {:ok, pid}
    end
  end

  # No turn survives a restart, so none owns a lock claim any more: those are
  # released and their waiters promoted. The channels that still have claims
  # get their channel servers, which wake the new holders and run the lease.
  # Only for the serving app: a `mix run` beside a running server must not
  # release the locks its turns hold.
  defp release_locks do
    Canopy.Locks.release_on_boot() |> Enum.each(&Canopy.Runtime.ensure_channel/1)
  rescue
    e -> Logger.warning("could not release locks at boot: #{Exception.message(e)}")
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CanopyWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
