defmodule Canopy.Memory do
  @moduledoc """
  What an agent knows across repositories: one Markdown document per agent,
  kept by Canopy rather than in any repository, so it follows the agent into
  every channel and DM. Agents read and write it through the `memory_read` and
  `memory_write` tools; the first part of it rides along in every system
  prompt. You can read and edit it on the agent's page.
  """

  alias Canopy.Memory.AgentMemory
  alias Canopy.Repo

  @max_bytes 64 * 1024
  @inline_chars 3_000
  @topic "memory"

  def max_bytes, do: @max_bytes
  def inline_chars, do: @inline_chars

  @doc "The agent's memory, or an empty string."
  @spec get(String.t()) :: String.t()
  def get(agent_id) when is_binary(agent_id) do
    case Repo.get(AgentMemory, agent_id) do
      %AgentMemory{body: body} -> body
      nil -> ""
    end
  end

  @doc "When the memory was last written, or nil."
  def updated_at(agent_id) do
    case Repo.get(AgentMemory, agent_id) do
      %AgentMemory{updated_at: at} -> at
      nil -> nil
    end
  end

  @doc "Replaces the memory. `{:error, :too_large}` past the size cap."
  @spec put(String.t(), String.t()) :: {:ok, String.t()} | {:error, :too_large}
  def put(agent_id, body) when is_binary(agent_id) and is_binary(body) do
    body = String.trim_trailing(body)

    if byte_size(body) > @max_bytes do
      {:error, :too_large}
    else
      now = DateTime.utc_now()

      Repo.insert!(
        %AgentMemory{agent_id: agent_id, body: body, inserted_at: now, updated_at: now},
        on_conflict: [set: [body: body, updated_at: now]],
        conflict_target: [:agent_id]
      )

      notify(agent_id)
      {:ok, body}
    end
  end

  @doc "Appends a block to the memory, separated by a blank line."
  def append(agent_id, text) when is_binary(text) do
    current = get(agent_id)
    text = String.trim(text)
    joined = if current == "", do: text, else: current <> "\n\n" <> text
    put(agent_id, joined)
  end

  @doc """
  The memory as it goes into a system prompt: everything when it is short,
  otherwise the first #{@inline_chars} characters and a pointer to the tool.
  """
  def for_prompt(nil), do: "Your memory across repositories is empty so far."

  def for_prompt(agent_id) do
    case get(agent_id) do
      "" ->
        "Your memory across repositories is empty so far."

      body when byte_size(body) <= @inline_chars ->
        "Your memory across repositories (read it; update it with canopy_memory_write before you finish when you learned something lasting):\n" <>
          body

      body ->
        String.slice(body, 0, @inline_chars) <>
          "\n…(memory continues; read all of it with canopy_memory_read.)"
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  defp notify(agent_id),
    do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, {:memory, :changed, agent_id})
end
