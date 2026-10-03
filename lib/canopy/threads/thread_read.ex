defmodule Canopy.Threads.ThreadRead do
  @moduledoc """
  The user's state in one thread: when they last read it, and whether they
  follow it (`nil` until decided, so auto-follow never undoes an unfollow).
  """

  use Ecto.Schema

  @primary_key false
  schema "thread_reads" do
    belongs_to :root, Canopy.Messages.Message, type: :string, primary_key: true
    belongs_to :user, Canopy.Users.User, type: :string, primary_key: true
    field :last_read_at, :utc_datetime_usec
    field :following, :boolean
    field :updated_at, :utc_datetime_usec
  end
end
