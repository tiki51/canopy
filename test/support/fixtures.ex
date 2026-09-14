defmodule Canopy.Fixtures do
  @moduledoc """
  Builders for context tests. `scenario/1` creates a repository, an owner agent,
  a channel (with task and membership), the local user, and the owner's root
  session in one call.
  """

  alias Canopy.{Agents, AgentSessions, Channels, Repositories, Users}

  @doc """
  Creates a throwaway git repository under `_build/test/tmp` and registers it.
  The directory is removed when the calling test exits.
  """
  def repository_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    path = Map.get_lazy(attrs, :path, &git_dir_fixture/0)

    {:ok, repository} =
      attrs
      |> Map.put(:path, path)
      |> Map.put_new(:name, Path.basename(path))
      |> Repositories.create(allow_outside_home: true)

    repository
  end

  @doc "Creates an empty initialized git repository and returns its absolute path."
  def git_dir_fixture do
    path =
      Path.join([File.cwd!(), "_build", "test", "tmp", "repo-" <> unique_suffix()])

    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", path])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Canopy Test"])
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  def user_fixture, do: Users.local()

  def agent_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    name = Map.get_lazy(attrs, :name, fn -> "agent-" <> unique_suffix() end)

    attrs =
      attrs
      |> Map.put(:name, name)
      |> Map.put_new(:role, "Test agent")
      |> Map.put_new(:system_prompt, "You are #{name}.")

    # Claude Code agents must name a model, an effort, and a permission mode
    attrs =
      if attrs[:engine] == "claude_code",
        do: attrs |> Map.put_new(:model_id, "haiku") |> Map.put_new(:effort, "low"),
        else: attrs

    {:ok, agent} = Agents.create(attrs)

    agent
  end

  def channel_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    repository_id = Map.get_lazy(attrs, :repository_id, fn -> repository_fixture().id end)
    owner_id = Map.get_lazy(attrs, :owner_agent_id, fn -> agent_fixture().id end)

    {:ok, channel} =
      attrs
      |> Map.put(:repository_id, repository_id)
      |> Map.put(:owner_agent_id, owner_id)
      |> Map.put_new(:name, "channel-" <> unique_suffix())
      |> Map.put_new(:topic, "Fix the thing")
      |> Channels.create()

    channel
  end

  def session_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    channel = Map.get_lazy(attrs, :channel, fn -> channel_fixture() end)

    {:ok, session} =
      attrs
      |> Map.delete(:channel)
      |> Map.put_new(:channel_id, channel.id)
      |> Map.put_new(:agent_id, channel.owner_agent_id)
      |> Map.put_new_lazy(:engine_session_id, fn -> "ses_" <> unique_suffix() end)
      |> AgentSessions.create()

    session
  end

  @doc """
  Returns `%{repository, agent, user, channel, task, session}` where `agent` owns
  the channel. Extra member agents can be passed as `members: [agent, ...]`.
  """
  def scenario(opts \\ []) do
    repository = repository_fixture()
    agent = agent_fixture()
    user = user_fixture()
    members = Keyword.get(opts, :members, [])

    channel =
      channel_fixture(%{
        repository_id: repository.id,
        owner_agent_id: agent.id,
        agent_ids: Enum.map(members, & &1.id)
      })

    session = session_fixture(%{channel: channel, agent_id: agent.id})

    %{
      repository: repository,
      agent: agent,
      user: user,
      channel: channel,
      task: channel.task,
      session: session
    }
  end

  def unique_suffix do
    System.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()
  end
end
