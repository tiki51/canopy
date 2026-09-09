defmodule Canopy.MCP.Tool do
  @moduledoc """
  Shared plumbing for Canopy tools.

  `run/3` resolves the caller's identity, hands the resulting context to the
  tool body, and turns `{:ok, text}` / `{:error, reason}` into MCP tool
  results. Tool bodies never see raw params before identity is known.
  """

  alias Anubis.Server.Response
  alias Canopy.{Agents, Channels}
  alias Canopy.MCP.Identity

  @identity_description "Set automatically by Canopy; never fill this in."

  @doc "Description for the `canopy_session_id` field every tool declares."
  def identity_description, do: @identity_description

  @doc """
  Resolves identity, then calls `fun.(ctx, params)`. `fun` returns
  `{:ok, text}` or `{:error, reason}`; both become tool responses.
  """
  def run(params, frame, fun) when is_function(fun, 2) do
    result =
      case Identity.resolve(params) do
        {:ok, ctx} -> fun.(ctx, params)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, text} when is_binary(text) -> reply(text, frame)
      {:error, reason} when is_binary(reason) -> error(reason, frame)
    end
  end

  @doc "A successful text tool result."
  def reply(text, frame), do: {:reply, Response.text(Response.tool(), text), frame}

  @doc "A failed tool result with a one-line reason."
  def error(reason, frame), do: {:reply, Response.error(Response.tool(), reason), frame}

  @doc """
  Resolves the optional `channel` argument. Nil or blank means the caller's
  own channel. Otherwise the value is a channel id or name inside the caller's
  repository, and the caller must be a member.
  """
  def resolve_channel(ctx, nil), do: {:ok, ctx.channel}

  def resolve_channel(ctx, value) when is_binary(value) do
    name = value |> String.trim() |> String.trim_leading("#")

    cond do
      name == "" ->
        {:ok, ctx.channel}

      name in [ctx.channel.id, ctx.channel.name] ->
        {:ok, ctx.channel}

      true ->
        lookup_channel(ctx, name)
    end
  end

  defp lookup_channel(ctx, name) do
    channel =
      if String.starts_with?(name, "ch_") do
        Channels.get(name)
      else
        Channels.get_by_name(ctx.repository.id, name)
      end

    cond do
      is_nil(channel) or channel.repository_id != ctx.repository.id ->
        {:error, "unknown channel ##{name}"}

      not Channels.member?(channel, ctx.agent) ->
        {:error, "not a member of ##{channel.name}"}

      true ->
        {:ok, channel}
    end
  end

  @doc "Resolves an agent reference: `@name`, `name`, or an agent id."
  def resolve_agent(nil), do: {:error, "missing agent name"}

  def resolve_agent(value) when is_binary(value) do
    ref = String.trim(value)

    agent =
      cond do
        ref == "" -> nil
        String.starts_with?(ref, "agt_") -> Agents.get(ref) || Agents.get_by_name(ref)
        true -> Agents.get_by_name(ref)
      end

    case agent do
      nil -> {:error, "unknown agent #{ref}"}
      agent -> {:ok, agent}
    end
  end

  @doc "Resolves an agent that must be a member of the channel and not the caller."
  def resolve_counterpart(ctx, channel, value, verb) do
    with {:ok, agent} <- resolve_agent(value) do
      cond do
        agent.id == ctx.agent.id ->
          {:error, "cannot #{verb} to yourself"}

        not Channels.member?(channel, agent) ->
          {:error, "@#{agent.name} is not a member of ##{channel.name}"}

        true ->
          {:ok, agent}
      end
    end
  end

  @doc "Clamps a limit argument into `1..max`, defaulting when absent."
  def clamp_limit(nil, default, _max), do: default
  def clamp_limit(limit, _default, max) when is_integer(limit) and limit > 0, do: min(limit, max)
  def clamp_limit(_, default, _max), do: default

  @doc "Trims a string argument; blank strings become nil."
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc "Turns a changeset error into a one-line reason."
  def changeset_reason(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  def changeset_reason(other), do: inspect(other)
end
