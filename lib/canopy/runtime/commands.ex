defmodule Canopy.Runtime.Commands do
  @moduledoc """
  Slash commands typed into the composer.

      /handoff @agent reason for the handoff
      /delegate @agent what the agent should do
      /i @agent [message]            (also /invite) adds the agent to the channel
      /i @team [message]             adds the team's active members
      /stop                          aborts every turn and holds the channel
      /playbook name [@coordinator] brief   starts a playbook run

  `parse/1` returns `{:command, name, target, text}`, `{:error, reason}` for a
  malformed command, or `:text` when the input is a normal message. Anything that
  starts with `/` but is not a known command is treated as text, so paths like
  `/lib/foo.ex` still work at the start of a message.
  """

  @commands %{
    "handoff" => :handoff,
    "delegate" => :delegate,
    "i" => :invite,
    "invite" => :invite,
    "stop" => :stop,
    "playbook" => :playbook
  }

  @type parsed ::
          :text
          | {:command, :handoff | :delegate | :invite | :stop | :playbook, String.t(), String.t()}
          | {:error, String.t()}

  @spec parse(String.t()) :: parsed
  def parse(input) when is_binary(input) do
    case Regex.run(~r/\A\/(\w+)(?:\s+(.*))?\z/s, String.trim(input)) do
      [_, name | rest] ->
        case Map.fetch(@commands, String.downcase(name)) do
          {:ok, command} -> parse_args(command, List.first(rest) || "")
          :error -> :text
        end

      nil ->
        :text
    end
  end

  def parse(_), do: :text

  @doc "Every command name, aliases included: what the composer highlights."
  def names, do: @commands |> Map.keys() |> Enum.sort()

  # One entry per command (aliases listed on it), in the order help/0 shows
  # them. `hint` is the composer help's wording; `prefill` is what the command
  # palette puts in the composer (nil: it runs straight away, as /stop does).
  @catalog [
    %{
      name: "i",
      aliases: ["invite"],
      usage: "/i @agent|@team [message]",
      hint: "/i @agent|@team invites",
      summary: "Invite an agent or a team into the channel",
      prefill: "/i @",
      dm?: false
    },
    %{
      name: "handoff",
      aliases: [],
      usage: "/handoff @agent reason",
      hint: "/handoff @agent reason",
      summary: "Ask a member to take over the channel's task",
      prefill: "/handoff @",
      dm?: true
    },
    %{
      name: "delegate",
      aliases: [],
      usage: "/delegate @agent task",
      hint: "/delegate @agent task",
      summary: "Delegate a subtask to a member",
      prefill: "/delegate @",
      dm?: true
    },
    %{
      name: "playbook",
      aliases: [],
      usage: "/playbook name [@coordinator] brief",
      hint: "/playbook name brief",
      summary: "Start a playbook run in the channel",
      prefill: "/playbook ",
      dm?: true
    },
    %{
      name: "stop",
      aliases: [],
      usage: "/stop",
      hint: "/stop stops everything",
      summary: "Stop every turn and hold the channel",
      prefill: nil,
      dm?: true
    }
  ]

  @doc """
  Every command once, with its aliases, usage, a one-line summary, what the
  command palette prefills in the composer (`nil`: it runs at once), and
  whether it can run in a DM (`dm?`). `help/0` is built from it, so the
  composer hint and the palette say the same thing.
  """
  def catalog, do: @catalog

  @doc "Short help shown in the composer."
  def help, do: Enum.map_join(@catalog, " · ", & &1.hint)

  # /stop takes nothing: whatever follows it is ignored.
  defp parse_args(:stop, _args), do: {:command, :stop, "", ""}

  # /playbook names a playbook (no @), then the brief, which may start with
  # an @coordinator.
  defp parse_args(:playbook, args) do
    case Regex.run(~r/\A([A-Za-z0-9][\w-]*)\s+(\S.*)\z/s, String.trim(args)) do
      [_, name, brief] -> {:command, :playbook, String.downcase(name), String.trim(brief)}
      nil -> {:error, usage(:playbook)}
    end
  end

  # /invite needs only a target; the message after it is optional.
  defp parse_args(command, args) do
    case Regex.run(~r/\A@?([A-Za-z0-9][\w-]*)\s*(.*)\z/s, String.trim(args)) do
      [_, target, text] when text != "" or command == :invite ->
        {:command, command, String.downcase(target), String.trim(text)}

      [_, _target, ""] ->
        {:error, usage(command)}

      nil ->
        {:error, usage(command)}
    end
  end

  defp usage(:handoff), do: "usage: /handoff @agent reason for the handoff"
  defp usage(:delegate), do: "usage: /delegate @agent what the agent should do"
  defp usage(:invite), do: "usage: /i @agent-or-team [message for them]"
  defp usage(:playbook), do: "usage: /playbook name [@coordinator] what the run is about"
end
