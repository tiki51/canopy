defmodule Canopy.ClaudeCode.Prompts do
  @moduledoc """
  The permission and question prompts Claude Code agents are waiting on.

  Claude Code asks through the `permission` MCP tool, whose call blocks until
  someone answers from the channel. The tool registers the prompt here
  (`open/4`), broadcasts the request so the runtime records a card, then
  `await/2`s; the runtime's reply arrives through `answer/2`. Registering
  before broadcasting means an answer can never arrive before anyone waits.

  Also remembers "always" replies per session for the rest of the process's
  life, so a tool approved with Always is not asked about again.
  """

  use GenServer

  @default_timeout_ms :timer.minutes(30)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers a prompt. `kind` is `:permission` or `:question`; `request` is what the card shows."
  def open(request_id, kind, session_id, request),
    do: GenServer.call(__MODULE__, {:open, request_id, kind, session_id, request})

  @doc "Blocks until the prompt is answered; `{:error, :timeout}` after `timeout`."
  def await(request_id, timeout \\ timeout_ms()) do
    GenServer.call(__MODULE__, {:await, request_id, timeout}, timeout + :timer.seconds(5))
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc "Answers a prompt; `{:error, :gone}` when nothing waits under that id."
  def answer(request_id, reply), do: GenServer.call(__MODULE__, {:answer, request_id, reply})

  @doc "Prompts still open, as `%{id, kind, session_id, request}` maps."
  def pending, do: GenServer.call(__MODULE__, :pending)

  @doc "Remembers that `tool` is always allowed for the session."
  def allow_always(session_id, tool), do: GenServer.call(__MODULE__, {:always, session_id, tool})

  @doc "Tools the session approved with Always."
  def always_list(session_id), do: GenServer.call(__MODULE__, {:always_list, session_id})

  @doc "How long a prompt may wait (`config :canopy, :claude_code, prompt_timeout_ms:`)."
  def timeout_ms,
    do:
      Keyword.get(
        Application.get_env(:canopy, :claude_code, []),
        :prompt_timeout_ms,
        @default_timeout_ms
      )

  @impl true
  def init(_opts), do: {:ok, %{open: %{}, always: %{}}}

  @impl true
  def handle_call({:open, id, kind, session_id, request}, _from, state) do
    entry = %{
      id: id,
      kind: kind,
      session_id: session_id,
      request: request,
      waiter: nil,
      reply: nil,
      timer: nil
    }

    {:reply, :ok, put_in(state, [:open, id], entry)}
  end

  def handle_call({:await, id, timeout}, from, state) do
    case state.open[id] do
      nil ->
        {:reply, {:error, :gone}, state}

      %{reply: reply} when reply != nil ->
        {:reply, {:ok, reply}, drop(state, id)}

      entry ->
        timer = Process.send_after(self(), {:expire, id}, timeout)
        {:noreply, put_in(state, [:open, id], %{entry | waiter: from, timer: timer})}
    end
  end

  def handle_call({:answer, id, reply}, _from, state) do
    case state.open[id] do
      nil ->
        {:reply, {:error, :gone}, state}

      %{waiter: nil} = entry ->
        {:reply, :ok, put_in(state, [:open, id], %{entry | reply: reply})}

      %{waiter: waiter, timer: timer} ->
        if timer, do: Process.cancel_timer(timer)
        GenServer.reply(waiter, {:ok, reply})
        {:reply, :ok, drop(state, id)}
    end
  end

  def handle_call(:pending, _from, state) do
    list = for {_, e} <- state.open, do: Map.take(e, [:id, :kind, :session_id, :request])
    {:reply, list, state}
  end

  def handle_call({:always, session_id, tool}, _from, state) do
    tools = Map.get(state.always, session_id, [])
    {:reply, :ok, put_in(state, [:always, session_id], Enum.uniq(tools ++ [tool]))}
  end

  def handle_call({:always_list, session_id}, _from, state),
    do: {:reply, Map.get(state.always, session_id, []), state}

  @impl true
  def handle_info({:expire, id}, state) do
    case state.open[id] do
      %{waiter: waiter} when waiter != nil ->
        GenServer.reply(waiter, {:error, :timeout})
        {:noreply, drop(state, id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp drop(state, id), do: %{state | open: Map.delete(state.open, id)}
end
