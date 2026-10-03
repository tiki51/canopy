defmodule CanopyWeb.TemplateController do
  @moduledoc """
  Exports as plain GET downloads (`Canopy.Templates`): one agent as
  `<name>.md`, several agents or a team as a zip, one playbook as its text.
  `memory=1` adds the agents' memory, which is otherwise never exported;
  `playbooks=1` adds a team's playbooks.

  Read-only, on 127.0.0.1: a page on another origin can start a download but
  can't read it.
  """

  use CanopyWeb, :controller

  alias Canopy.{Agents, Playbooks, Teams, Templates}
  alias CanopyWeb.Download

  def agent(conn, %{"id" => id} = params) do
    case Agents.get(id) do
      nil ->
        not_found(conn)

      agent ->
        {filename, text} = Templates.export_agent(agent, memory: flag?(params, "memory"))
        Download.send_attachment(conn, filename, "text/markdown; charset=utf-8", text)
    end
  end

  def agents(conn, params) do
    ids = params |> Map.get("ids", []) |> List.wrap() |> Enum.filter(&is_binary/1)

    case Enum.flat_map(ids, &List.wrap(Agents.get(&1))) do
      [] ->
        not_found(conn)

      agents ->
        {filename, zip} = Templates.export_agents(agents, memory: flag?(params, "memory"))
        Download.send_attachment(conn, filename, "application/zip", zip)
    end
  end

  def team(conn, %{"id" => id} = params) do
    case Teams.get(id) do
      nil ->
        not_found(conn)

      team ->
        {filename, zip} =
          Templates.export_team(team,
            memory: flag?(params, "memory"),
            playbooks: flag?(params, "playbooks")
          )

        Download.send_attachment(conn, filename, "application/zip", zip)
    end
  end

  def playbook(conn, %{"id" => id}) do
    case Playbooks.get(id) do
      nil ->
        not_found(conn)

      playbook ->
        {filename, text} = Templates.export_playbook(playbook)
        Download.send_attachment(conn, filename, "text/markdown; charset=utf-8", text)
    end
  end

  defp flag?(params, key), do: Map.get(params, key) in ["1", "true", "on"]

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(CanopyWeb.ErrorHTML)
    |> render(:"404")
  end
end
