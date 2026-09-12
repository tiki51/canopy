defmodule Canopy.Runtime.Commands do
  @moduledoc """
  Slash commands typed into the composer.

      /handoff @agent reason for the handoff
      /delegate @agent what the agent should do
      /i @agent [message]            (also /invite) adds the agent to the channel

  `parse/1` returns `{:command, name, target, text}`, `{:error, reason}` for a
  malformed command, or `:text` when the input is a normal message. Anything that
  starts with `/` but is not a known command is treated as text, so paths like
  `/lib/foo.ex` still work at the start of a message.
  """

  @commands %{"handoff" => :handoff, "delegate" => :delegate, "i" => :invite, "invite" => :invite}

  @type parsed ::
          :text
          | {:command, :handoff | :delegate | :invite, String.t(), String.t()}
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

  @doc "Short help shown in the composer."
  def help, do: "/i @agent invites · /handoff @agent reason · /delegate @agent task"

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
  defp usage(:invite), do: "usage: /i @agent [message for them]"
end
