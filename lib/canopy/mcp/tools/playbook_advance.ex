defmodule Canopy.MCP.Tools.PlaybookAdvance do
  @moduledoc """
  Move a playbook run on, when the current step's "Done when" holds. Only
  the run's coordinator can. Records `result` on the step (later steps and
  the user read it there), then returns the next step's header and
  instructions. `next` jumps to any step (back to fix after a failed
  review); `skip` skips an optional step, or any step with the reason in
  result. A step that needs the user's approval is held for them: post your
  summary, end your turn, and Canopy wakes you with their answer.
  """

  use Anubis.Server.Component, type: :tool

  alias Canopy.MCP.{PlaybookText, Tool}
  alias Canopy.Playbooks.Runs

  schema do
    field :canopy_session_id, :string, description: Tool.identity_description()

    field :result, {:required, :string},
      description: "The evidence that the step is done: findings, files, commands and outcomes."

    field :run, :string,
      description: "The run id (pbr_…). Defaults to the run in progress in your channel."

    field :next, :string, description: "The step to go to, by id. Defaults to the following step."
    field :skip, :boolean, description: "Skip the current step instead of completing it."
  end

  @impl true
  def execute(params, frame) do
    Tool.run(params, frame, fn ctx, params ->
      with {:ok, run} <- PlaybookText.find_run(ctx, Tool.blank_to_nil(Map.get(params, :run))),
           {:ok, run, what} <-
             Runs.advance(run, {:agent, ctx.agent.id},
               result: Map.get(params, :result),
               next: Tool.blank_to_nil(Map.get(params, :next)),
               skip: Map.get(params, :skip) == true
             ) do
        {:ok, reply(run, what)}
      end
    end)
  end

  defp reply(run, :awaiting_approval) do
    step = Runs.current_step(run)

    "#{run.playbook_name} [#{run.id}]: \"#{step.title}\" is waiting for the user's approval. " <>
      "Post your summary for them, then end your turn; Canopy wakes you with their answer."
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
