defmodule Canopy.Costs.Auditor do
  @moduledoc """
  The agent the user asks to review spend. Picked on the Costs page and kept
  in settings; an audit is a message from the user in a DM with that agent,
  pointing it at `canopy_costs_report`, so the reply lands where the user
  reads it and the agent can dig further with the tool.
  """

  alias Canopy.{Agents, Channels, Runtime, Settings}
  alias Canopy.Agents.Agent

  @doc "The auditor, or nil when none is picked (or it was removed)."
  def agent do
    case Settings.get().auditor_agent_id do
      nil -> nil
      id -> Agents.get(id)
    end
  end

  @doc "Picks the auditor (nil or \"\" to clear)."
  def assign(agent_id) when agent_id in [nil, ""], do: Settings.update(%{auditor_agent_id: nil})

  def assign(agent_id) when is_binary(agent_id) do
    case Agents.get(agent_id) do
      %Agent{} -> Settings.update(%{auditor_agent_id: agent_id})
      nil -> {:error, :unknown_agent}
    end
  end

  @doc """
  Asks the auditor for an audit in a DM under `repository_id`, with an optional
  focus from the user. Returns the DM so the caller can navigate there.
  """
  def request(repository_id, focus \\ nil) when is_binary(repository_id) do
    with %Agent{} = agent <- agent() || {:error, :no_auditor},
         {:ok, dm} <- Channels.ensure_dm(repository_id, agent),
         {:ok, _message} <- Runtime.post_user_message(dm.id, prompt(agent, focus)) do
      {:ok, dm}
    end
  end

  @doc false
  def prompt(agent, focus) do
    focus = if is_binary(focus) and String.trim(focus) != "", do: String.trim(focus)

    """
    @#{agent.name} please audit what my agents are spending and recommend how to cut it.

    Pull the numbers with `canopy_costs_report` (period `week` first; `all` for the long view, `today` if something is running away). Then tell me, briefly and with numbers:

    1. Where the money goes: which agents, channels, models, and triggers cost the most, and whether that matches the value of the work.
    2. What looks wasteful: turns that passed without replying, turns that ended in errors, long contexts, agent-to-agent chatter, scheduled tasks that fire too often, delegations that bounce.
    3. Concrete changes ranked by expected saving: a cheaper model for a specific agent, a lower chatter limit, a spend limit on a channel, a schedule to slow down or cancel, a prompt or workflow to change. Say what each would save and what it would cost us in quality.

    You cannot change models, limits, or settings yourself; I will. Keep it under a page.#{if focus, do: "\n\nFocus on: " <> focus, else: ""}
    """
    |> String.trim()
  end
end
