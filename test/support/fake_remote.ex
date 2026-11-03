defmodule Canopy.Playbooks.Sharing.FakeRemote do
  @moduledoc """
  An in-memory GitHub repository for playbook sharing tests
  (`config :canopy, :playbook_sharing, remote: ...`), held in one named Agent.
  Calls come from the Refresher and from `start_async` tasks as well as the
  test process, so it's global: tests that use it are `async: false`.

  Most tests go through `Canopy.PlaybookSharingHelpers.stub_remote/2`; the
  functions here change the repository afterwards (`put_file/2`,
  `merge_pr/1`, …) and read what export sent (`opened_prs/0`).
  `hold/1` makes a callback block until `release/1`, so a test can look at a
  page while a call is in flight.
  """

  @behaviour Canopy.Playbooks.Sharing.Remote

  use Agent

  @default %{
    files: %{},
    folder: "playbooks",
    no_folder: false,
    default_branch: "main",
    can_push?: true,
    account: "sbarber",
    prs: %{},
    opened: [],
    fail: %{},
    held: MapSet.new(),
    commits: %{},
    calls: []
  }

  @raw %{
    gh_missing: "gh is not installed",
    gh_too_old: "gh version 1.9.0 is too old",
    gh_signed_out: "You are not logged into any GitHub hosts. Run gh auth login to authenticate.",
    not_found: "Not Found (HTTP 404)",
    read_only: "Resource not accessible by integration (HTTP 403)",
    pr_failed: "Validation Failed (HTTP 422)",
    stale: "stale",
    gh_failed: "API rate limit exceeded (HTTP 403)"
  }

  def start_link(_opts \\ []), do: Agent.start_link(fn -> @default end, name: __MODULE__)

  @doc "Starts the fake (or empties a running one) with `state` merged over the defaults."
  def load(state \\ %{}) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> Map.merge(@default, state) end)
  end

  # unlinked, so it outlives the test that started it; `load/1` empties it
  defp ensure_started do
    case Agent.start(fn -> @default end, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @doc "Puts a file (`path` relative to the repository root) with this text."
  def put_file(path, text), do: update(&put_in(&1.files[path], text))

  def delete_file(path), do: update(&%{&1 | files: Map.delete(&1.files, path)})

  @doc "Merges an open PR: its files land in the repository."
  def merge_pr(number) do
    update(fn state ->
      pr = Map.fetch!(state.prs, number)
      files = Enum.reduce(pr.files, state.files, fn f, acc -> Map.put(acc, f.path, f.content) end)
      %{state | files: files, prs: Map.put(state.prs, number, %{pr | state: :merged})}
    end)
  end

  def close_pr(number),
    do: update(&put_in(&1.prs[number], %{&1.prs[number] | state: :closed}))

  def set_push(can_push?), do: update(&%{&1 | can_push?: can_push?})

  @doc "Makes `callback` (`:account`, `:repo`, `:list`, `:read`, `:open_pr`, `:pr`, `:last_commit`) fail with `kind`; nil clears it."
  def fail(callback, nil), do: update(&%{&1 | fail: Map.delete(&1.fail, callback)})
  def fail(callback, kind), do: update(&put_in(&1.fail[callback], kind))

  @doc "What export sent, oldest first: `%{number, title, body, base, branch, files: [%{path, content}]}`."
  def opened_prs, do: get(& &1.opened) |> Enum.reverse()

  @doc "The callbacks called so far, oldest first."
  def calls, do: get(& &1.calls) |> Enum.reverse()

  @doc "Blocks calls to `callback` until `release/1`."
  def hold(callback), do: update(&%{&1 | held: MapSet.put(&1.held, callback)})

  @doc "Lets held calls to `callback` (or every callback, with no argument) go on."
  def release(callback), do: update(&%{&1 | held: MapSet.delete(&1.held, callback)})
  def release, do: update(&%{&1 | held: MapSet.new()})

  @doc "The git blob sha of a text, as GitHub computes it."
  def blob_sha(text) do
    :crypto.hash(:sha, "blob #{byte_size(text)}\0" <> text) |> Base.encode16(case: :lower)
  end

  # -- Remote ---------------------------------------------------------------------

  @impl true
  def account, do: call(:account, fn s -> {:ok, s.account} end)

  @impl true
  def repo(_repo),
    do:
      call(:repo, fn s -> {:ok, %{default_branch: s.default_branch, can_push?: s.can_push?}} end)

  @impl true
  def list(_repo, _branch, folder, _etag) do
    call(:list, fn s ->
      files =
        for {path, text} <- s.files, in_folder?(path, folder) do
          %{path: path, sha: blob_sha(text), size: byte_size(text)}
        end

      if s.no_folder or files == [],
        do: {:ok, :no_folder},
        else: {:ok, %{etag: nil, files: Enum.sort_by(files, & &1.path)}}
    end)
  end

  @impl true
  def read(_repo, sha) do
    call(:read, fn s ->
      texts =
        Map.values(s.files) ++
          Enum.flat_map(s.prs, fn {_, pr} -> Enum.map(pr.files, & &1.content) end)

      case Enum.find(texts, &(blob_sha(&1) == sha)) do
        nil -> {:error, {:not_found, @raw.not_found}}
        text -> {:ok, text}
      end
    end)
  end

  @impl true
  def last_commit(_repo, _branch, path) do
    call(:last_commit, fn s ->
      {:ok, Map.get(s.commits, path, %{by: "mkoh", at: ~U[2026-10-30 12:00:00Z]})}
    end)
  end

  @impl true
  def open_pr(repo, base, branch, files, title, body) do
    call(:open_pr, fn s ->
      if s.can_push? do
        number = (s.prs |> Map.keys() |> Enum.max(fn -> 0 end)) + 1
        url = "https://github.com/#{repo}/pull/#{number}"
        branch = free_branch(branch, Enum.map(s.opened, & &1.branch))

        pr = %{
          number: number,
          title: title,
          body: body,
          base: base,
          branch: branch,
          files: files,
          state: :open
        }

        state = %{s | prs: Map.put(s.prs, number, pr), opened: [pr | s.opened]}
        {{:ok, %{number: number, url: url, branch: branch}}, state}
      else
        {:error, {:read_only, @raw.read_only}}
      end
    end)
  end

  # like GH.create_branch: `-2`, `-3`… while the name is taken
  defp free_branch(branch, taken) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&if(&1 == 1, do: branch, else: "#{branch}-#{&1}"))
    |> Enum.find(&(&1 not in taken))
  end

  @impl true
  def pr(_repo, number) do
    call(:pr, fn s ->
      case s.prs[number] do
        nil -> {:error, {:not_found, @raw.not_found}}
        pr -> {:ok, pr.state}
      end
    end)
  end

  # Runs `fun` on the state unless the callback is set to fail; `fun` may
  # return `{reply, new_state}` to change it. A held callback waits first.
  defp call(callback, fun) do
    ensure_started()
    wait_while_held(callback)

    Agent.get_and_update(__MODULE__, fn s ->
      s = %{s | calls: [callback | s.calls]}

      case s.fail[callback] do
        nil ->
          case fun.(s) do
            {{_, _} = reply, %{} = new_state} -> {reply, new_state}
            reply -> {reply, s}
          end

        kind ->
          {{:error, {kind, @raw[kind] || "failed"}}, s}
      end
    end)
  end

  defp wait_while_held(callback) do
    if get(&MapSet.member?(&1.held, callback)) do
      Process.sleep(10)
      wait_while_held(callback)
    end
  end

  defp in_folder?(path, folder) when folder in [nil, ""], do: not String.contains?(path, "/")
  defp in_folder?(path, folder), do: Path.dirname(path) == folder

  defp get(fun) do
    ensure_started()
    Agent.get(__MODULE__, fun)
  end

  defp update(fun) do
    ensure_started()
    Agent.update(__MODULE__, fun)
  end
end
