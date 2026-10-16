defmodule Canopy.MCP.Tools.PlaybookStart do
  @moduledoc """
  Start a playbook run. You coordinate it: follow each step's instructions,
  delegate each step to its owner, and advance with canopy_playbook_advance.
  Canopy fills the roles (from the playbook's team and roles; `assign`
  overrides them) and adds anyone missing to the channel. With a
  `channel_name` the run gets a new channel, owned by you, and you are woken
  there; otherwise it runs in this channel and this call returns the first
  step's instructions. One run at a time per channel.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{PlaybookText, Tool}
  alias Canopy.Playbooks
  alias Canopy.Playbooks.Runs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()
    field :name, {:required, :string}, description: "The playbook's name."

    field :brief, :string,
      description:
        "What this run is about, self-contained: everything the playbook's inputs ask for. Leave it out when the playbook is context enough."

    field :channel_name, :string,
      description:
        "Run it in a new channel with this name (you own it). Without it, the run happens in this channel."

    field :section, :string,
      description:
        "With channel_name: the sidebar section to file the new channel under, by name (canopy_channels_list shows the sections); an existing one matches in any case, otherwise it is created. Defaults to the playbook's section:, and an agent can't ask for no section when the playbook has one. Ignored without channel_name: a run never moves a channel."

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
               section: Tool.blank_to_nil(Map.get(params, :section)),
               assign: Tool.blank_to_nil(Map.get(params, :assign))
             }) do
        {:ok, reply(run, new?, Tool.blank_to_nil(Map.get(params, :section)))}
      end
    end)
  end

  defp find(name) do
    case Tool.blank_to_nil(name) && Playbooks.get_by_name(name) do
      nil -> {:error, "no playbook named #{inspect(name)}; canopy_playbooks_list shows them"}
      playbook -> {:ok, playbook}
    end
  end

  defp reply(run, true, _section) do
    "started #{run.playbook_name} [#{run.id}] in the new channel ##{run.channel.name}#{section_note(run.channel.section)} (you own it; members joined). " <>
      "You will be woken there with the first step; there is nothing more to do here."
  end

  defp reply(run, false, section) do
    step = Runs.current_step(run)

    ignored =
      if section,
        do: "; section ignored: the run is in this channel, which keeps its place",
        else: ""

    "started #{run.playbook_name} [#{run.id}] in ##{run.channel.name}; you coordinate it#{ignored}.\n" <>
      "Now: " <>
      PlaybookText.step_header(run, step) <>
      "\n" <>
      PlaybookText.step_instructions(run, step) <>
      "\n\nWhen this step's work is done, call canopy_playbook_advance with the evidence in result."
  end

  defp section_note(%Canopy.Channels.Section{created?: true, name: name}),
    do: ", in the new section #{name}"

  defp section_note(%Canopy.Channels.Section{name: name}), do: ", in section #{name}"
  defp section_note(_), do: ""
end
