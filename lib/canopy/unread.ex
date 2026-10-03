defmodule Canopy.Unread do
  @moduledoc """
  What the user has not read yet, per channel: how many agent messages arrived
  since they last had the channel open, and how many of those mention them.

  Reading is coarse on purpose: having the channel open counts as reading
  everything in it. System notes and the user's own messages never count.

  A reply that stays in its thread does not make the channel unread, unless
  it mentions the user; one also sent to the channel does. Threads have their
  own read state (`Canopy.Threads`): `thread_summary/1` counts the unread
  replies in the threads the user follows.
  """

  import Ecto.Query

  alias Canopy.Repo
  alias Canopy.Threads.ThreadRead
  alias Canopy.Unread.ChannelRead
  alias Canopy.Users.User

  @type summary :: %{optional(String.t()) => %{count: pos_integer, mentions: non_neg_integer}}

  @doc "Records that the user has seen everything in the channel as of now."
  def mark_read(channel_id, %User{id: user_id}), do: mark_read(channel_id, user_id)

  def mark_read(channel_id, user_id) when is_binary(channel_id) and is_binary(user_id) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ChannelRead{channel_id: channel_id, user_id: user_id, last_read_at: now},
      on_conflict: [set: [last_read_at: now]],
      conflict_target: [:channel_id, :user_id]
    )

    :ok
  end

  @doc """
  Unread counts for every channel that has any, keyed by channel id. A message
  mentions the user when it contains `@` followed by their display name, in any
  case and as a whole name (`mentions?/2`, recorded on the message when it is
  posted).
  """
  @spec summary(User.t()) :: summary
  def summary(%User{id: user_id}) do
    from(m in Canopy.Messages.Message,
      left_join: r in ChannelRead,
      on: r.channel_id == m.channel_id and r.user_id == ^user_id,
      where: not is_nil(m.agent_id) and m.kind != "system",
      where: is_nil(r.last_read_at) or m.inserted_at > r.last_read_at,
      where: is_nil(m.thread_id) or m.sent_to_channel or m.mentions_user,
      group_by: m.channel_id,
      select:
        {m.channel_id, count(m.id),
         sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.mentions_user))}
    )
    |> Repo.all()
    |> Map.new(fn {channel_id, count, mentions} ->
      {channel_id, %{count: count, mentions: mentions || 0}}
    end)
  end

  @doc """
  The followed threads with replies the user has not read, keyed by root id:
  `%{root_id => %{channel_id, count}}`. Only agents' replies count, as in
  `summary/1`; a thread never opened since it was followed counts every one.
  """
  @spec thread_summary(User.t()) :: %{
          optional(String.t()) => %{channel_id: String.t(), count: pos_integer}
        }
  def thread_summary(%User{id: user_id}) do
    from(r in ThreadRead,
      join: m in Canopy.Messages.Message,
      on: m.thread_id == r.root_id,
      where: r.user_id == ^user_id and r.following == true,
      where: not is_nil(m.agent_id) and m.kind != "system",
      where: is_nil(r.last_read_at) or m.inserted_at > r.last_read_at,
      group_by: [r.root_id, m.channel_id],
      select: {r.root_id, m.channel_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new(fn {root_id, channel_id, count} ->
      {root_id, %{channel_id: channel_id, count: count}}
    end)
  end

  @doc """
  True when `body` mentions the user as `@` + their display name, in any case,
  as a whole name: `@you,` and `@You.` mention "You", `@youngblood` does not.
  The sidebar's mention count and desktop notifications both rest on it.
  """
  def mentions?(body, %User{display_name: name}) when is_binary(body) do
    # A blank display name would make every `@` a mention; it matches nothing.
    case String.trim(name || "") do
      "" ->
        false

      name ->
        needle = Regex.escape("@" <> String.downcase(name))
        Regex.match?(~r/#{needle}(?![\p{L}\p{N}_-])/u, String.downcase(body))
    end
  end

  def mentions?(_body, _user), do: false
end
