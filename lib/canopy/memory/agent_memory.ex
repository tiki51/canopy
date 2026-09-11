defmodule Canopy.Memory.AgentMemory do
  @moduledoc "An agent's memory across repositories: one Markdown document."

  use Ecto.Schema

  @primary_key false
  schema "agent_memories" do
    belongs_to :agent, Canopy.Agents.Agent, type: :string, primary_key: true
    field :body, :string, default: ""
    timestamps(type: :utc_datetime_usec)
  end
end
