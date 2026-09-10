defmodule Canopy.Unread do
  @moduledoc """
  What the user has not read yet, per channel: how many agent messages arrived
  since they last had the channel open, and how many of those mention them.

  Reading is coarse on purpose: having the channel open counts as reading
  everything in it. System notes and the user's own messages never count.
  """

  import Ecto.Query

  alias Canopy.Repo
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
  case.
  """
  @spec summary(User.t()) :: summary
  def summary(%User{id: user_id, display_name: name}) do
    needle = "@" <> String.downcase(name || "")

    from(m in Canopy.Messages.Message,
      left_join: r in ChannelRead,
      on: r.channel_id == m.channel_id and r.user_id == ^user_id,
      where: not is_nil(m.agent_id) and m.kind != "system",
      where: is_nil(r.last_read_at) or m.inserted_at > r.last_read_at,
      group_by: m.channel_id,
      select:
        {m.channel_id, count(m.id),
         sum(fragment("CASE WHEN instr(lower(?), ?) > 0 THEN 1 ELSE 0 END", m.body, ^needle))}
    )
    |> Repo.all()
    |> Map.new(fn {channel_id, count, mentions} ->
      {channel_id, %{count: count, mentions: mentions || 0}}
    end)
  end
end
