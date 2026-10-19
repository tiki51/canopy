defmodule Canopy.EnvironmentTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures
  import Canopy.EnvironmentHelpers

  alias Canopy.{Agents, Documents, Environment, Messages, Repo, Seeds, Settings}
  alias Canopy.Environment.{Clear, FakeBackup, Resetter}

  setup do
    Resetter.forget()
    Environment.subscribe()

    on_exit(fn ->
      Application.delete_env(:canopy, :seed_hook)
      Resetter.reopen()
      Resetter.forget()
      File.rm_rf!(FakeBackup.dir())
    end)

    :ok
  end

  # a channel with a message, a document, a memory, a team and a cost row
  defp workspace do
    %{channel: channel, agent: agent, user: user, repository: repository} = scenario()
    {:ok, _} = Messages.post_user_note(channel.id, user.id, "hello")

    {:ok, document} =
      Documents.create(%{
        filename: "notes.txt",
        source: {:binary, "twelve bytes"},
        user_id: user.id,
        origin_channel_id: channel.id
      })

    {:ok, _} = Canopy.Memory.put(agent.id, "remember this")
    team = team_fixture([agent])

    {:ok, _} =
      Canopy.Timeline.record(%{
        channel_id: channel.id,
        agent_id: agent.id,
        event_type: "agent_turn_completed",
        payload: %{"cost" => 0.25}
      })

    %{channel: channel, agent: agent, repository: repository, document: document, team: team}
  end

  defp count(table), do: Repo.aggregate(from(t in table), :count)

  defp reset!(opts \\ []) do
    assert {:ok, id} = Environment.reset(opts)
    await_reset()
    id
  end

  # Holds a seed open (Environment.seed/0 waiting in its hook) so a reset
  # started now waits in :stopping. Returns the seed's task; send it :go.
  defp hold_seed do
    test = self()

    Application.put_env(:canopy, :seed_hook, fn ->
      send(test, {:seed_held, self()})

      receive do
        :go -> :ok
      end
    end)

    task = Task.async(&Environment.seed/0)
    assert_receive {:seed_held, pid}
    Application.delete_env(:canopy, :seed_hook)
    {task, pid}
  end

  describe "preview/0" do
    test "counts what a reset deletes and keeps" do
      %{document: document} = workspace()
      {:ok, _} = Canopy.Channels.ensure_dm(repository_fixture().id, agent_fixture())

      preview = Environment.preview()

      assert preview.deleted == %{
               channels: 1,
               dms: 1,
               messages: count("messages"),
               agents: count("agents"),
               teams: 1,
               playbooks: 0,
               runs: 0,
               tasks: count("tasks"),
               schedules: 0,
               watches: 0,
               memories: 1,
               documents: 1,
               document_bytes: document.byte_size,
               cost_usd: 0.25,
               cost_estimated: 0.0
             }

      assert preview.deleted.messages >= 1
      assert preview.kept == %{repositories: 2}
      assert preview.backup_path =~ ~r"/canopy_test\.\d{4}-\d\d-\d\dT\d{4}\.db$"
    end
  end

  describe "reset/1" do
    test "deletes the workspace, keeps settings, the user and repositories, and reseeds" do
      %{document: document, repository: repository} = workspace()
      {:ok, _} = Settings.update(%{collaboration_prompt: "Be brief."})
      token = Settings.mcp_token()
      settings_before = Settings.get()
      user = Canopy.Users.local()
      keep = Path.join(Documents.Store.dir(), "keep.txt")
      File.write!(keep, "not a document")
      on_exit(fn -> File.rm(keep) end)

      {:ok, _} = Canopy.GlobalPermissions.grant(hd(Agents.list()).id, "Bash")

      assert {:ok, id} = Environment.reset()
      assert Environment.status() != :idle
      await_reset()

      for {step, index} <- [stopping: 1, backing_up: 2, clearing: 3, seeding: 4] do
        assert_received {:environment,
                         {:reset_step, %{id: ^id, step: ^step, index: ^index, total: 4}}}
      end

      assert_received {:environment, {:reset_done, result}}
      refute_received {:environment, _}

      assert %{id: ^id, status: :done, backup_path: backup, seed: seed} = result
      assert String.starts_with?(id, "rst_")
      assert File.exists?(backup)
      assert length(seed.created) == length(Seeds.agent_names()) + 3
      assert Environment.last_reset() == result
      assert Environment.status() == :idle
      refute Environment.resetting?()

      # cleared, then reseeded
      for table <- Clear.cleared_tables() -- ~w(agents teams team_members playbooks),
          do: assert(count(table) == 0, table)

      assert Enum.sort(Enum.map(Agents.list(), & &1.name)) == Enum.sort(Seeds.agent_names())
      assert Enum.map(Canopy.Teams.list(), & &1.name) == ["bugfix-team"]

      # kept
      settings = Settings.get()
      assert settings.mcp_token == token
      assert settings.collaboration_prompt == "Be brief."
      assert settings.auditor_agent_id == Agents.get_by_name("finops").id
      # every other column, field by field (the seeder's auditor update bumps updated_at)
      changed = [:__meta__, :auditor_agent_id, :updated_at]

      for {field, value} <- Map.drop(Map.from_struct(settings_before), changed) do
        assert Map.fetch!(settings, field) == value, "settings.#{field} changed"
      end

      assert Canopy.Users.local() == user
      assert Canopy.Repositories.get!(repository.id)

      # the documents' bytes go, nothing else in the files dir does
      refute Documents.Store.exists?(document.id)
      assert File.exists?(keep)
    end

    test "a failed backup deletes nothing and has no backup path" do
      workspace()
      before = count("messages")
      fail_reset_at(:backing_up)

      id = reset!()

      assert_received {:environment,
                       {:reset_failed,
                        %{id: ^id, step: :backing_up, deleted?: false, backup_path: nil} = f}}

      assert f.reason == "injected failure"
      assert count("messages") == before
      refute Environment.resetting?()
      assert File.ls(FakeBackup.dir()) in [{:ok, []}, {:error, :enoent}]
    end

    test "a failed delete rolls back, and the failure has the backup path" do
      %{document: document} = workspace()
      before = count("messages")
      fail_reset_at(:clearing)

      id = reset!()

      assert_received {:environment,
                       {:reset_failed, %{id: ^id, step: :clearing, deleted?: false} = f}}

      assert File.exists?(f.backup_path)
      assert count("messages") == before
      assert Documents.Store.exists?(document.id)
      refute Environment.resetting?()
    end

    test "a failed seed comes after the delete" do
      workspace()
      fail_reset_at(:seeding)

      id = reset!()

      assert_received {:environment,
                       {:reset_failed, %{id: ^id, step: :seeding, deleted?: true} = f}}

      assert File.exists?(f.backup_path)
      assert count("messages") == 0
      assert Agents.list() == []
    end

    test "a failed file sweep still seeds, and is reported as :clearing" do
      workspace()
      fail_reset_at(:sweeping)

      id = reset!()

      assert_received {:environment,
                       {:reset_failed, %{id: ^id, step: :clearing, deleted?: true} = f}}

      assert f.reason == "injected failure"
      assert File.exists?(f.backup_path)
      assert Agents.get_by_name("backend")
    end

    test "a failed sweep and a failed seed report the seed" do
      fail_reset_at([:sweeping, :seeding])

      id = reset!()

      assert_received {:environment, {:reset_failed, %{id: ^id, step: :seeding, deleted?: true}}}
    end

    test "waits for a seed in flight; meanwhile resets, seeds and channels are refused" do
      %{channel: channel} = workspace()
      {:ok, server} = Canopy.Runtime.ensure_channel(channel.id, start_stream: false)
      ref = Process.monitor(server)
      {task, seed_pid} = hold_seed()

      assert {:ok, id} = Environment.reset()
      assert {:error, :already_running} = Environment.reset()
      assert {:error, :resetting} = Environment.seed()
      assert {:error, :resetting} = Canopy.Runtime.ensure_channel(channel.id)
      assert Environment.resetting?()
      assert {:running, %{id: ^id, step: :stopping, index: 1}} = Environment.status()

      # still held in :stopping: the channel is still up
      refute_received {:environment, {:reset_step, %{step: :backing_up}}}
      assert Process.alive?(server)

      send(seed_pid, :go)
      assert {:ok, _report} = Task.await(task)
      await_reset()

      assert_received {:environment, {:reset_done, %{id: ^id}}}
      assert_received {:DOWN, ^ref, :process, ^server, _}
      assert Canopy.Runtime.Supervisor.whereis(channel.id) == nil

      # the seed's rows were cleared and seeded again, once
      assert length(Agents.list()) == length(Seeds.agent_names())
    end

    test "step_delay_ms holds each step open" do
      started = System.monotonic_time(:millisecond)
      assert {:ok, id} = Environment.reset(step_delay_ms: 50)

      assert {:running, %{id: ^id, step: :stopping}} = Environment.status()
      assert Environment.resetting?()

      await_reset()
      assert System.monotonic_time(:millisecond) - started >= 200
      assert_received {:environment, {:reset_done, %{id: ^id}}}
    end

    test "a seed refused while the gate is up" do
      raise_gate()
      assert {:error, :resetting} = Environment.seed()
    end
  end

  describe "the gate can't stick" do
    test "a killed worker fails the run and lowers the gate" do
      {task, seed_pid} = hold_seed()
      assert {:ok, id} = Environment.reset()
      %{run: %{pid: worker}} = :sys.get_state(Resetter)

      Process.exit(worker, :kill)
      assert_receive {:environment, {:reset_failed, failure}}
      refute Environment.resetting?()

      assert %{id: ^id, step: :stopping, deleted?: false, backup_path: nil} = failure
      assert failure.reason =~ "stopped unexpectedly"
      assert Environment.status() == :idle

      send(seed_pid, :go)
      Task.await(task)
    end

    test "a worker killed after the commit is reported as :seeding" do
      {task, seed_pid} = hold_seed()
      assert {:ok, id} = Environment.reset()
      %{run: %{pid: worker}} = :sys.get_state(Resetter)

      send(Resetter, {:committed, id})
      Process.exit(worker, :kill)

      assert_receive {:environment, {:reset_failed, %{id: ^id, step: :seeding, deleted?: true}}}
      refute Environment.resetting?()

      send(seed_pid, :go)
      Task.await(task)
    end

    test "a stale :DOWN doesn't end the current run" do
      {task, seed_pid} = hold_seed()
      assert {:ok, id} = Environment.reset()

      send(Resetter, {:DOWN, make_ref(), :process, self(), :normal})
      assert {:running, %{id: ^id}} = Environment.status()
      assert Environment.resetting?()

      send(seed_pid, :go)
      Task.await(task)
      await_reset()
      assert_received {:environment, {:reset_done, %{id: ^id}}}
    end

    @tag :capture_log
    test "a Resetter restart lowers a raised gate" do
      raise_gate()
      old = Process.whereis(Resetter)

      GenServer.stop(Resetter, :shutdown)
      new = wait_for_restart(old)

      assert new != old
      refute Environment.resetting?()
    end
  end

  test "error_message/1 drops the SQL statement from a SQLite error" do
    error = %Exqlite.Error{
      message: "database is locked",
      statement: "BEGIN IMMEDIATE TRANSACTION"
    }

    assert Environment.error_message(error) == "database is locked"
    assert Environment.error_message(RuntimeError.exception("boom")) == "boom"
  end

  test "every table is either kept or cleared" do
    assert Clear.unclassified_tables() == []
    assert MapSet.disjoint?(MapSet.new(Clear.kept_tables()), MapSet.new(Clear.cleared_tables()))
  end

  defp wait_for_restart(old, tries \\ 100) do
    case Process.whereis(Resetter) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when tries > 0 ->
        Process.sleep(10)
        wait_for_restart(old, tries - 1)
    end
  end
end
