defmodule Canopy.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :canopy

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Starts the release without its HTTP server and seeds missing defaults."
  def seed do
    endpoint_config =
      @app
      |> Application.fetch_env!(CanopyWeb.Endpoint)
      |> Keyword.put(:server, false)

    Application.put_env(@app, CanopyWeb.Endpoint, endpoint_config, persistent: true)
    {:ok, _} = Application.ensure_all_started(@app)
    Canopy.Seeds.run()
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
