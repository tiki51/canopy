defmodule Canopy.MCP.Tools.PlaybookAdvance do
  @moduledoc """
  Move a playbook run on, when the current step's "Done when" holds. Only
  the run's coordinator can. Records `result` on the step (later steps and
  the user read it there), then returns the next step's header and
  instructions. `next` jumps to any step (back to fix after a failed
  review); `skip` skips an optional step, or any step with the reason in
  result. A step that needs the user's approval is held for them with a
  sign-off card in the channel (its summary is your result; `question`,
  `options` and `attachments` shape it): end your turn, and Canopy wakes
  you with their answer.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{PlaybookText, Tool}
  alias Canopy.Playbooks.Runs
  alias Canopy.Signoffs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :result, {:required, :string},
      description: "The evidence that the step is done: findings, files, commands and outcomes."

    field :run, :string,
      description: "The run id (pbr_…). Defaults to the run in progress in your channel."

    field :next, :string, description: "The step to go to, by id. Defaults to the following step."
    field :skip, :boolean, description: "Skip the current step instead of completing it."

    field :question, :string,
      description:
        "For a step held for the user's sign-off: the one line on its card. Default: Is \"<step title>\" done?"

    embeds_many :options,
      description:
        "For a step held for sign-off: choices (2–6) the user accepts one of. The pick is added to the step result and sent back to you; the run then moves on as a normal approval." do
      field :label, {:required, :string}
      field :description, :string
      field :recommended, :boolean
    end

    field :attachments, :string,
      description: "For a step held for sign-off: doc ids or paths shown on its card."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      opts = [
        result: Map.get(params, :result),
        next: Tool.blank_to_nil(Map.get(params, :next)),
        skip: Map.get(params, :skip) == true
      ]

      with {:ok, run} <- PlaybookText.find_run(ctx, Tool.blank_to_nil(Map.get(params, :run))),
           {:ok, signoff} <- signoff_params(ctx, run, opts, params),
           {:ok, run, what} <-
             Runs.advance(run, {:agent, ctx.agent.id}, [signoff: signoff] ++ opts) do
        {:ok, reply(run, what) <> ignored(what, params)}
      end
    end)
  end

  # The card's fields, for an advance that holds the step. Attachment paths
  # are shared as documents only then, so an advance that moves on shares nothing.
  defp signoff_params(ctx, run, opts, params) do
    if Runs.holds?(run, opts) do
      with {:ok, document_ids} <-
             Tool.resolve_attachments(
               ctx,
               ctx.channel,
               Tool.blank_to_nil(Map.get(params, :attachments))
             ) do
        {:ok,
         %{
           question: Tool.blank_to_nil(Map.get(params, :question)),
           options: Map.get(params, :options) || [],
           document_ids: document_ids
         }
         |> Map.reject(fn {_key, value} -> value in [nil, []] end)}
      end
    else
      {:ok, %{}}
    end
  end

  # card fields on an advance that held nothing are dropped, and said so
  defp ignored(:awaiting_approval, _params), do: ""

  defp ignored(_what, params) do
    given? =
      Tool.blank_to_nil(Map.get(params, :question)) != nil or
        (Map.get(params, :options) || []) != [] or
        Tool.blank_to_nil(Map.get(params, :attachments)) != nil

    if given?,
      do: "\n(question/options/attachments were ignored: this step is not held for sign-off.)",
      else: ""
  end

  defp reply(run, :awaiting_approval) do
    step = Runs.current_step(run)

    card =
      case Signoffs.pending_for_run(run.id) do
        nil -> "its sign-off card"
        signoff -> "the card [#{signoff.id}]"
      end

    "#{run.playbook_name} [#{run.id}]: \"#{step.title}\" is waiting for the user's sign-off: " <>
      "#{card} is in the channel. Post nothing more about it and end your turn; Canopy wakes you with their answer."
  end

  defp reply(run, :completed) do
    "#{run.playbook_name} [#{run.id}] is complete: that was the last step. Wrap up (the channel task, a short closing note if useful)."
  end

  defp reply(run, {:step, _id}) do
    step = Runs.current_step(run)

    "#{run.playbook_name} [#{run.id}] moved on. Now: " <>
      PlaybookText.step_header(run, step) <> "\n" <> PlaybookText.step_instructions(run, step)
  end
end
