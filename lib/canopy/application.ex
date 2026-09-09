defmodule Canopy.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CanopyWeb.Telemetry,
      Canopy.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:canopy, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:canopy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Canopy.PubSub},
      # Start a worker by calling: Canopy.Worker.start_link(arg)
      # {Canopy.Worker, arg},
      # Start to serve requests, typically the last entry
      CanopyWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Canopy.Supervisor]
    Supervisor.start_link(children, opts)
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
