defmodule CanopyWeb.DmController do
  @moduledoc """
  Opens the direct-message channel between the user and an agent, creating it
  on first use, then redirects into it.

  A DM lives in a repository like any channel (the agent needs a working
  directory), so `?repository=<id>` picks one; without it the current
  repository is the first one on file.
  """

  use CanopyWeb, :controller

  alias Canopy.{Agents, Channels, Repositories}

  def show(conn, %{"agent_id" => agent_id} = params) do
    with {:agent, %{} = agent} <- {:agent, Agents.get(agent_id)},
         {:repository, %{} = repository} <- {:repository, pick_repository(params["repository"])},
         {:ok, channel} <- Channels.ensure_dm(repository.id, agent) do
      redirect(conn, to: ~p"/channels/#{channel.id}")
    else
      {:agent, nil} ->
        conn |> put_flash(:error, "That agent no longer exists.") |> redirect(to: ~p"/agents")

      {:repository, nil} ->
        conn
        |> put_flash(:error, "Add a repository before messaging an agent.")
        |> redirect(to: ~p"/repositories")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not open a direct message with that agent.")
        |> redirect(to: ~p"/agents")
    end
  end

  defp pick_repository(nil), do: List.first(Repositories.list())

  defp pick_repository(id) when is_binary(id),
    do: Enum.find(Repositories.list(), &(&1.id == id)) || pick_repository(nil)
end
