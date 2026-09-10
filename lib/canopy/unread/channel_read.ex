defmodule Canopy.Unread.ChannelRead do
  @moduledoc "When the user last had a channel open."

  use Ecto.Schema

  @primary_key false
  schema "channel_reads" do
    belongs_to :channel, Canopy.Channels.Channel, type: :string, primary_key: true
    belongs_to :user, Canopy.Users.User, type: :string, primary_key: true
    field :last_read_at, :utc_datetime_usec
  end
end
