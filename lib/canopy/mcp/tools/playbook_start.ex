defmodule Canopy.MCP.Tools.PlaybookStart do
  @moduledoc """
  Start a playbook run. You coordinate it: follow each step's instructions,
  delegate each step to its owner, and advance with canopy_playbook_advance.
  Canopy fills the roles (from the playbook's team and roles; `assign`
  overrides them) and adds anyone missing to the channel. A playbook that
  runs in a new channel (or a `channel_name`) gets one, owned by you, and
  you are woken there; otherwise this call returns the first step's
  instructions. One run at a time per channel.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{PlaybookText, Tool}
  alias Canopy.Playbooks
  alias Canopy.Playbooks.Runs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :name, {:required, :string}, description: "The playbook's name."

    field :brief, {:required, :string},
      description:
        "What this run is about, self-contained: everything the playbook's inputs ask for."

    field :channel_name, :string,
      description: "Run it in a new channel with this name (you own it) instead of this one."

    field :assign, :string,
      description: "Role overrides, comma separated: \"fix=@fullstack, test=@qa\"."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, playbook} <- find(Map.get(params, :name)),
           {:ok, run, new?} <-
             Runs.start(%{
               playbook: playbook,
               channel: ctx.channel,
               coordinator: ctx.agent,
               started_by_agent_id: ctx.agent.id,
               brief: Map.get(params, :brief),
               channel_name: Tool.blank_to_nil(Map.get(params, :channel_name)),
               assign: Tool.blank_to_nil(Map.get(params, :assign))
             }) do
        {:ok, reply(run, new?)}
      end
    end)
  end

  defp find(name) do
    case Tool.blank_to_nil(name) && Playbooks.get_by_name(name) do
      nil -> {:error, "no playbook named #{inspect(name)}; canopy_playbooks_list shows them"}
      playbook -> {:ok, playbook}
    end
  end

  defp reply(run, true) do
    "started #{run.playbook_name} [#{run.id}] in the new channel ##{run.channel.name} (you own it; members joined). " <>
      "You will be woken there with the first step; there is nothing more to do here."
  end

  defp reply(run, false) do
    step = Runs.current_step(run)

    "started #{run.playbook_name} [#{run.id}] in ##{run.channel.name}; you coordinate it.\n" <>
      "Now: " <>
      PlaybookText.step_header(run, step) <>
      "\n" <>
      PlaybookText.step_instructions(run, step) <>
      "\n\nWhen this step's work is done, call canopy_playbook_advance with the evidence in result."
  end
end
