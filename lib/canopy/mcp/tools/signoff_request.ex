defmodule Canopy.MCP.Tools.SignoffRequest do
  @moduledoc """
  Ask the user to sign off on your work: a card in your channel with Accept
  and Reject, or one Accept per option plus Reject all. Don't wait for it:
  end your turn, and the user's answer reaches you as a new message, which
  also lands in the channel. For a playbook step that needs the user's
  approval, use canopy_playbook_advance instead (it takes options too).
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.Tool
  alias Canopy.Playbooks.{Run, Runs}
  alias Canopy.Signoffs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :title, {:required, :string},
      description: "Short subject for the card header, e.g. \"Header design\" (≤80 chars)."

    field :question, {:required, :string},
      description:
        "One line the user answers, e.g. \"Which header design should we build?\" (≤300 chars)."

    field :summary, :string, description: "Optional Markdown: what you did, what to look at."

    embeds_many :options,
      description:
        "Optional choices (2–6). Each gets its own Accept; the card adds Reject all. Omit for a plain Accept / Reject." do
      field :label, {:required, :string}
      field :description, :string
      field :recommended, :boolean
    end

    field :attachments, :string,
      description:
        "Comma-separated doc ids or repository paths, shown as chips (like canopy_message_send)."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, aside} <- check_run(ctx),
           {:ok, document_ids} <-
             Tool.resolve_attachments(
               ctx,
               ctx.channel,
               Tool.blank_to_nil(Map.get(params, :attachments))
             ),
           {:ok, signoff} <-
             Signoffs.request(%{
               channel_id: ctx.channel.id,
               agent_id: ctx.agent.id,
               title: Map.get(params, :title),
               question: Map.get(params, :question),
               summary: Tool.blank_to_nil(Map.get(params, :summary)),
               options: Map.get(params, :options) || [],
               document_ids: document_ids
             }) do
        {:ok,
         "Sign-off card [#{signoff.id}] is up in ##{ctx.channel.name}. End your turn: the user's answer reaches you as a new message, which also lands in the channel." <>
           aside}
      end
    end)
  end

  # No freestanding card may pass for a playbook step's card: while a step
  # is held, nobody asks; on an approval step, its coordinator holds the
  # step instead, and anyone else is told their card does not release it.
  defp check_run(ctx) do
    case Runs.active_for_channel(ctx.channel.id) do
      %Run{status: "awaiting_approval"} = run ->
        {:error,
         "the user is already signing off step #{run.current_step} of #{run.playbook_name} on its card; wait for that answer"}

      %Run{} = run ->
        case Runs.current_step(run) do
          %{approval: true, step_id: step_id} ->
            if run.coordinator_agent_id == ctx.agent.id,
              do:
                {:error,
                 "step #{step_id} is a sign-off step: hold it with canopy_playbook_advance (it takes options too)"},
              else:
                {:ok,
                 " This card does not release step #{step_id}; report the user's pick through your delegation."}

          _ ->
            {:ok, ""}
        end

      nil ->
        {:ok, ""}
    end
  end
end
