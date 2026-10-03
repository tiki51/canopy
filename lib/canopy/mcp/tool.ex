defmodule Canopy.MCP.Tool do
  @moduledoc """
  Shared plumbing for Canopy tools.

  `run/3` resolves the caller's identity, hands the resulting context to the
  tool body, and turns `{:ok, text}` / `{:error, reason}` into MCP tool
  results. Tool bodies never see raw params before identity is known.
  """

  alias Anubis.Server.Response
  alias Canopy.Repositories
  alias Canopy.{Agents, Channels, Documents, Teams}
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
      case Identity.resolve(params, frame) do
        {:ok, ctx} -> fun.(ctx, params)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, text} when is_binary(text) -> reply(text, frame)
      {:ok, text, {:image, data, mime}} -> reply_with_image(text, data, mime, frame)
      {:error, reason} when is_binary(reason) -> error(reason, frame)
    end
  end

  @doc "A text result followed by an image content block (base64 `data`)."
  def reply_with_image(text, data, mime, frame) do
    response = Response.tool() |> Response.text(text) |> Response.image(data, mime)
    {:reply, response, frame}
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

  @doc """
  A message the caller may read, by id: it must be in the caller's
  repository, in a channel the caller belongs to. `{:ok, message}` (with the
  usual preloads) or a one-line error.
  """
  def readable_message(ctx, id) do
    with %Canopy.Messages.Message{} = message <- blank_to_nil(id) && Canopy.Messages.get(id),
         channel = Channels.get!(message.channel_id),
         true <- channel.repository_id == ctx.repository.id || {:error, "unknown message"} do
      if Channels.member?(channel, ctx.agent),
        do: {:ok, message},
        else: {:error, "not a member of ##{channel.name}"}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "unknown message #{inspect(id)}"}
    end
  end

  @doc "A registered repository by name or id; nil means the caller's own."
  def resolve_repository(ctx, nil), do: {:ok, ctx.repository}

  def resolve_repository(ctx, value) when is_binary(value) do
    ref = String.trim(value)

    cond do
      ref == "" ->
        {:ok, ctx.repository}

      true ->
        case Enum.find(Repositories.list(), &(&1.id == ref or &1.name == ref)) do
          nil ->
            {:error,
             "unknown repository #{inspect(ref)}; registered: " <>
               Enum.map_join(Repositories.list(), ", ", & &1.name)}

          repository ->
            {:ok, repository}
        end
    end
  end

  @doc """
  Resolves an agent reference: `@name`, `name`, or an agent id. A team's name
  is an error that names its members, so the caller can pick one; `verb`
  words it ("delegate" gives "delegate to one member").
  """
  def resolve_agent(value, verb \\ nil)

  def resolve_agent(nil, _verb), do: {:error, "missing agent name"}

  def resolve_agent(value, verb) when is_binary(value) do
    ref = String.trim(value)

    case find_agent(ref) do
      nil ->
        case ref != "" && Teams.get_by_name(ref) do
          %Teams.Team{} = team -> {:error, team_not_agent(team, verb)}
          _ -> {:error, "unknown agent #{ref}"}
        end

      agent ->
        {:ok, agent}
    end
  end

  defp find_agent(""), do: nil
  defp find_agent("agt_" <> _ = ref), do: Agents.get(ref) || Agents.get_by_name(ref)
  defp find_agent(ref), do: Agents.get_by_name(ref)

  defp team_not_agent(team, verb) do
    action = if verb, do: "#{verb} to", else: "name"

    "@#{team.name} is a team; #{action} one member: " <>
      Enum.map_join(Teams.active_members(team), ", ", &("@" <> &1.name))
  end

  @doc """
  Resolves a comma or space separated list of agent and team references to
  `{:ok, agents, teams}`: the agents named directly and the teams named (an
  agent wins a name collision). `except:` drops one agent id (the caller)
  from the direct list. Unknown names and deactivated agents are errors;
  duplicates collapse.
  """
  def resolve_members(nil, _opts), do: {:ok, [], []}

  def resolve_members(value, opts) when is_binary(value) do
    except = Keyword.get(opts, :except)

    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, [], []}, fn ref, {:ok, agents, teams} ->
      case find_agent(ref) do
        %{id: ^except} ->
          {:cont, {:ok, agents, teams}}

        %{active: false} ->
          {:halt, {:error, "#{ref} is deactivated"}}

        %Agents.Agent{} = agent ->
          {:cont, {:ok, agents ++ [agent], teams}}

        nil ->
          case Teams.get_by_name(ref) do
            nil -> {:halt, {:error, "unknown agent or team #{ref}"}}
            team -> {:cont, {:ok, agents, teams ++ [team]}}
          end
      end
    end)
    |> case do
      {:ok, agents, teams} -> {:ok, Enum.uniq_by(agents, & &1.id), Enum.uniq_by(teams, & &1.id)}
      error -> error
    end
  end

  @doc """
  Like `resolve_members/2`, flattened to agents: each team stands for its
  active members (the `except:` id dropped).
  """
  def resolve_agents(value, opts) do
    except = Keyword.get(opts, :except)

    with {:ok, agents, teams} <- resolve_members(value, opts) do
      members =
        teams
        |> Enum.flat_map(&Teams.active_members/1)
        |> Enum.reject(&(&1.id == except))

      {:ok, Enum.uniq_by(agents ++ members, & &1.id)}
    end
  end

  @doc "Resolves an agent that must be a member of the channel and not the caller."
  def resolve_counterpart(ctx, channel, value, verb) do
    with {:ok, agent} <- resolve_agent(value, verb) do
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

  @doc """
  Resolves an `attachments` argument: a comma-separated list of document ids
  (`doc_…`) and repository-relative paths. Paths are shared as new documents
  first, credited to the caller and the channel. Returns `{:ok, ids}` in the
  given order or a one-line error naming the bad item.
  """
  def resolve_attachments(_ctx, _channel, nil), do: {:ok, []}

  def resolve_attachments(ctx, channel, value) when is_binary(value) do
    items =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if length(items) > Canopy.Messages.max_attachments() do
      {:error, "at most #{Canopy.Messages.max_attachments()} attachments per message"}
    else
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case resolve_attachment(ctx, channel, item) do
          {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp resolve_attachment(_ctx, _channel, "doc_" <> _ = id) do
    case Documents.get(id) do
      nil -> {:error, "unknown document #{id}"}
      _ -> {:ok, id}
    end
  end

  defp resolve_attachment(ctx, channel, path) do
    case Documents.create_from_repository(ctx.repository.path, path, %{
           agent_id: ctx.agent.id,
           origin_channel_id: channel && channel.id
         }) do
      {:ok, document} -> {:ok, document.id}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, changeset} -> {:error, "could not share #{path}: " <> changeset_reason(changeset)}
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
