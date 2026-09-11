defmodule Canopy.Messages.MessageRead do
  @moduledoc "The newest message an agent has read in a channel through `messages_read`."

  use Ecto.Schema

  @primary_key false
  schema "message_reads" do
    belongs_to :agent, Canopy.Agents.Agent, type: :string, primary_key: true
    belongs_to :channel, Canopy.Channels.Channel, type: :string, primary_key: true
    field :last_message_id, :string
    field :updated_at, :utc_datetime_usec
  end
end
