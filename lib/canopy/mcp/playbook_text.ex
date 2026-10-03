defmodule Canopy.MCP.PlaybookText do
  @moduledoc """
  What the playbook tools say back: a run's state, a step's header and
  instructions, and the lookup of the run a call is about (the id given, or
  the caller's channel's run in progress).
  """

  alias Canopy.Delegations.Delegation
  alias Canopy.MCP.Format
  alias Canopy.Playbooks
  alias Canopy.Playbooks.{Definition, Run, Runs, Step}

  @doc """
  The run a call names (`ref`), in a channel the caller is a member of, or
  the run in progress in the caller's channel.
  """
  def find_run(ctx, nil) do
    case Runs.active_for_channel(ctx.channel.id) do
      nil ->
        {:error, "no playbook run is in progress in ##{ctx.channel.name}; pass run with its id"}

      run ->
        {:ok, run}
    end
  end

  # Only a run in a channel the caller is a member of: a run elsewhere (another
  # channel, a DM) is as unknown to it as one that does not exist.
  def find_run(ctx, ref) when is_binary(ref) do
    case Runs.get(String.trim(ref)) do
      %Run{channel: channel} = run ->
        if Canopy.Channels.member?(channel, ctx.agent),
          do: {:ok, run},
          else: {:error, "unknown playbook run #{ref}"}

      nil ->
        {:error, "unknown playbook run #{ref}"}
    end
  end

  @doc "`step 4/6 verify \"Verify\", round 1, owners @test`."
  def step_header(%Run{steps: steps}, %Step{} = step) do
    owners =
      case Runs.owner_names(step) do
        [] -> ""
        names -> ", owners " <> Enum.join(names, ", ")
      end

    gate = if step.approval, do: ", needs the user's approval", else: ""

    "step #{step.position}/#{length(steps)} #{step.step_id} \"#{step.title}\", round #{max(step.round, 1)}#{owners}#{gate}"
  end

  @doc "The step's instructions from the run's snapshot, or a line saying there are none."
  def step_instructions(%Run{} = run, %Step{} = step) do
    with {:ok, definition} <- Playbooks.definition(run),
         section when is_binary(section) and section != "" <-
           Definition.step_section(definition, step.step_id) do
      "Instructions for #{step.step_id}:\n" <> section
    else
      _ -> "(the playbook has no instructions for #{step.step_id}; use its title and the brief)"
    end
  end

  @doc "A run's whole state: roster, steps with status, round, result, and delegations."
  def run_block(%Run{} = run) do
    roster =
      run.roster
      |> Enum.sort()
      |> Enum.map_join(", ", fn {role, id} -> "#{role}=" <> agent_name(id) end)

    steps = Enum.map_join(run.steps, "\n", &step_line(run, &1))
    current = Runs.current_step(run)

    head =
      "#{run.playbook_name} run [#{run.id}] in ##{run.channel.name}: #{status_text(run)}; " <>
        "coordinator #{Format.agent_ref(run.coordinator)}; started by #{starter(run)}."

    changed =
      if Runs.definition_changed?(run),
        do:
          "\n(The playbook was edited since this run started; the run keeps the text it started with.)",
        else: ""

    tail =
      case current do
        nil -> ""
        step -> "\n\nCurrent: " <> step_header(run, step) <> "\n" <> step_instructions(run, step)
      end

    head <>
      changed <>
      "\nBrief: #{run.brief}" <>
      "\nRoster: #{if roster == "", do: "(coordinator only)", else: roster}" <>
      "\nSteps:\n" <> steps <> tail
  end

  defp status_text(%Run{status: "active"}), do: "active"
  defp status_text(%Run{status: "awaiting_approval"}), do: "waiting for the user's approval"
  defp status_text(%Run{status: status, outcome: nil}), do: status

  defp status_text(%Run{status: status, outcome: outcome}),
    do: "#{status} (#{Format.truncate(Format.single_line(outcome), 160)})"

  defp starter(%Run{started_by: nil, trigger: %{} = trigger}) when map_size(trigger) > 0,
    do: "a GitHub watch (#{trigger["key"]})"

  defp starter(%Run{started_by: nil}), do: "the user"
  defp starter(%Run{started_by: agent}), do: Format.agent_ref(agent)

  defp step_line(_run, %Step{} = step) do
    owners =
      case Runs.owner_names(step) do
        [] -> ""
        names -> " · " <> Enum.join(names, ", ")
      end

    round = if step.round > 1, do: " (round #{step.round})", else: ""
    gate = if step.approval, do: " [approval]", else: ""
    optional = if step.optional, do: " [optional]", else: ""

    result =
      case step.result do
        nil -> ""
        text -> "\n   result: " <> Format.truncate(Format.single_line(text), 300)
      end

    delegations =
      case List.wrap(step.delegations) do
        [] ->
          ""

        list ->
          "\n   delegations: " <>
            Enum.map_join(list, "; ", fn %Delegation{} = d ->
              "#{d.id} #{Format.agent_ref(d.to_agent)} #{d.status}"
            end)
      end

    "#{step.position}. #{step.step_id} \"#{step.title}\" — #{step.status}#{round}#{gate}#{optional}#{owners}#{result}#{delegations}"
  end

  defp agent_name(id) do
    case Canopy.Agents.get(id) do
      nil -> id
      agent -> "@" <> agent.name
    end
  end

  @doc "A playbook in a list: name, description, roles, and step titles."
  def playbook_line(playbook) do
    case Playbooks.definition(playbook) do
      {:ok, d} ->
        roles = Definition.owner_roles(d)
        team = if d.team, do: "; team @#{d.team}", else: ""
        channel = if d.channel == "new", do: "; runs in a new channel", else: ""

        "- #{d.name} — #{d.description}\n  roles: #{if roles == [], do: "(coordinator only)", else: Enum.join(roles, ", ")}#{team}#{channel}\n  steps: " <>
          Enum.map_join(d.steps, " → ", & &1.title)

      {:error, _} ->
        "- #{playbook.name} — #{playbook.description} (does not parse; the user should fix it)"
    end
  end
end
