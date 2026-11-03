defmodule Canopy.Playbooks.Sharing do
  @moduledoc """
  Sharing playbooks through a GitHub repository: one Markdown file per
  playbook in a folder (Settings → Playbook sharing). Import copies files into
  the library; export opens a pull request; nothing is pushed to a branch
  anyone works on, and nothing syncs on its own.

  Each playbook may follow one file (its origin: repo, path, the version and
  text at the last sync). Comparing your text, GitHub's and that base gives
  each entry its state (`Canopy.Playbooks.Sharing.State`). `version` is a
  number users see, separate from `lock_version`; it's written into the file
  on export as a `version:` line and never stored in the body.

  GitHub is reached through `Canopy.Playbooks.Sharing.Remote` (the user's
  `gh`). Every function that reaches it is synchronous and may take as long
  as gh does (30 s a call), so pages call them in `start_async`. Errors are
  `{:error, {kind, raw}}`, `raw` being gh's or GitHub's own text.

  PubSub on `"playbook_sharing"`: `{:playbook_sharing, :status, status}`
  after every successful read, `{:playbook_sharing, :config_changed}` after
  `save_config/1`. Import, undo, export and a merged PR also send
  `{:playbooks, :changed}`.
  """

  import Ecto.Query, warn: false

  alias Canopy.Playbooks
  alias Canopy.Playbooks.{Playbook, Run}
  alias Canopy.Playbooks.Sharing.{Compare, Refresher, Remote, State, Text}
  alias Canopy.{Repo, Settings}

  @topic "playbook_sharing"
  # files read per folder; export's staleness check sees the whole listing
  @max_files 200

  @type config :: %{repo: String.t(), branch: String.t() | nil, folder: String.t()}
  @type error :: {atom(), String.t()}

  # -- Config -------------------------------------------------------------------

  @doc "The sharing settings, or `:not_set_up` when no repository is set."
  @spec config() :: {:ok, config()} | :not_set_up
  def config do
    setting = Settings.get()

    case setting.playbook_repo do
      repo when is_binary(repo) and repo != "" ->
        {:ok,
         %{repo: repo, branch: setting.playbook_branch, folder: setting.playbook_folder || ""}}

      _ ->
        :not_set_up
    end
  end

  @config_types %{repo: :string, branch: :string, folder: :string}

  @doc """
  A changeset for the sharing form (`repo`, `branch`, `folder`), from the
  saved settings and `attrs`: the repo `owner/name`, or blank to turn sharing
  off; the branch a valid branch name or blank; the folder `/`-separated
  segments or blank for the repository root.
  """
  def change_config(attrs \\ %{}) do
    current =
      case config() do
        {:ok, config} -> config
        :not_set_up -> %{repo: nil, branch: nil, folder: Settings.get().playbook_folder || ""}
      end

    {current, @config_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@config_types), empty_values: [])
    |> Ecto.Changeset.update_change(:repo, &trim/1)
    |> Ecto.Changeset.update_change(:branch, &trim/1)
    |> Ecto.Changeset.update_change(:folder, &(&1 |> trim() |> to_string() |> String.trim("/")))
    |> Ecto.Changeset.validate_change(:repo, fn :repo, repo ->
      if Canopy.GitHub.valid_repo?(repo), do: [], else: [repo: "must be owner/name"]
    end)
    |> Ecto.Changeset.validate_change(:branch, fn :branch, branch ->
      if Canopy.GitHub.valid_ref?(branch),
        do: [],
        else: [branch: "isn't a branch name GitHub accepts"]
    end)
    |> Ecto.Changeset.validate_change(:folder, fn :folder, folder ->
      if Settings.Setting.valid_folder?(folder),
        do: [],
        else: [folder: "must be a folder path like playbooks or team/playbooks"]
    end)
  end

  defp trim(nil), do: nil

  defp trim(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Saves the sharing settings (`repo`, `branch`, `folder`, string or atom
  keys) and returns `config/0`: a blank repo turns sharing off
  (`:not_set_up`), leaving playbooks' links and versions alone.
  `{:error, changeset}` is `change_config/1`'s, for the form. Forgets the
  cached status and broadcasts `{:playbook_sharing, :config_changed}`.
  """
  def save_config(attrs) do
    changeset = change_config(attrs)

    with {:ok, values} <- Ecto.Changeset.apply_action(changeset, :validate),
         {:ok, _setting} <-
           Settings.update(%{
             playbook_repo: values.repo,
             playbook_branch: values.branch,
             playbook_folder: values.folder || ""
           }) do
      Refresher.clear()
      broadcast({:playbook_sharing, :config_changed})
      config()
    else
      {:error, %Ecto.Changeset{data: %Settings.Setting{}} = settings_changeset} ->
        # the same rules apply on both sides, so this is not expected; carry
        # its errors onto the form's fields
        {:error,
         Enum.reduce(settings_changeset.errors, %{changeset | action: :validate}, fn
           {field, {message, opts}}, acc ->
             Ecto.Changeset.add_error(acc, form_field(field), message, opts)
         end)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp form_field(:playbook_repo), do: :repo
  defp form_field(:playbook_branch), do: :branch
  defp form_field(:playbook_folder), do: :folder
  defp form_field(other), do: other

  @doc """
  Reads a repository location: `owner/name`, `https://github.com/o/r`, or
  `.../tree/<branch>/<folder…>` (the first segment after `tree/` is the
  branch, the rest the folder; a branch with `/` has to be typed). `:error`
  when it isn't one.
  """
  def parse_location(text) when is_binary(text) do
    path =
      text
      |> String.trim()
      |> String.replace(~r/[?#].*\z/, "")
      |> String.replace(~r/\Ahttps?:\/\//i, "")
      |> String.replace(~r/\A(www\.)?github\.com\//i, "")
      |> String.trim("/")

    case String.split(path, "/") do
      [owner, name | rest] ->
        repo = owner <> "/" <> String.replace_suffix(name, ".git", "")

        with true <- Canopy.GitHub.valid_repo?(repo),
             {:ok, branch, folder} <- location_rest(rest) do
          %{repo: repo, branch: branch, folder: folder}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_location(_), do: :error

  defp location_rest([]), do: {:ok, nil, nil}

  defp location_rest(["tree", branch | folder]) do
    folder = if folder == [], do: nil, else: Enum.join(folder, "/")

    if Canopy.GitHub.valid_ref?(branch) and Settings.Setting.valid_folder?(folder),
      do: {:ok, branch, folder},
      else: :error
  end

  defp location_rest(_), do: :error

  # -- Reading ------------------------------------------------------------------

  @doc """
  Checks a config before it's saved (the form's values): who gh is signed in
  as, push access, the branch read (the default one when blank), whether the
  folder exists, and how many playbook files it has.
  """
  def check(config) do
    changeset = change_config(Map.new(config, fn {k, v} -> {to_string(k), v} end))

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:error, changeset} ->
        {:error, {:not_found, changeset_text(changeset)}}

      {:ok, values} ->
        config = %{repo: values.repo, branch: values.branch, folder: values.folder || ""}
        remote = Remote.impl()

        with {:ok, account} <- remote.account(),
             {:ok, repo} <- remote.repo(config.repo),
             branch = config.branch || repo.default_branch,
             {:ok, listing} <- list(remote, config, branch, nil) do
          {:ok,
           %{
             account: account,
             can_push?: repo.can_push?,
             branch: branch,
             folder?: listing != :no_folder,
             count: if(listing == :no_folder, do: 0, else: min(length(listing.files), @max_files))
           }}
        end
    end
  end

  defp changeset_text(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  @doc """
  The sharing status: cached when it's for the current settings and at most
  `max_age` seconds old (default 600), else read now; `max_age: 0` always
  reads. Callers during a read share it. A read that takes over 120 s
  returns `:gh_failed` (it keeps going and fills the cache).
  """
  def status(opts \\ []) do
    max_age = Keyword.get(opts, :max_age, 600)

    case config() do
      :not_set_up ->
        {:error, {:not_set_up, "playbook sharing isn't set up"}}

      {:ok, config} ->
        try do
          case Refresher.snapshot(config, max_age) do
            {:ok, snapshot} -> {:ok, build_status(snapshot)}
            {:error, _} = error -> error
          end
        catch
          :exit, {:timeout, _} -> {:error, {:gh_failed, "timed out reading GitHub"}}
        end
    end
  end

  @doc """
  The last status read for the current settings, with the local side
  recomputed from the database (so it follows edits at once), or nil. Never
  calls gh.
  """
  def cached_status do
    with {:ok, config} <- config(),
         %{config: ^config} = snapshot <- Refresher.cached() do
      {:ok, build_status(snapshot)}
    else
      _ -> nil
    end
  end

  defp build_status(snapshot) do
    %{entries: entries} = State.build(snapshot, all_playbooks())
    status(snapshot, entries)
  end

  defp status(snapshot, entries) do
    snapshot
    |> Map.take([:config, :branch, :account, :can_push?, :folder?, :checked_at])
    |> Map.put(:entries, entries)
  end

  defp all_playbooks, do: Repo.all(from p in Playbook, order_by: [asc: p.name])

  @doc false
  # The Refresher's read (in a task): GitHub's side, then the local writes it
  # implies (linking equal name pairs, merged or closed pull requests), then
  # the status. `listing` is the last listing for this config, for its ETag.
  def read(config, listing) do
    remote = Remote.impl()

    with {:ok, account} <- remote.account(),
         {:ok, repo} <- remote.repo(config.repo),
         branch = config.branch || repo.default_branch,
         {:ok, listing} <- fresh_listing(remote, config, branch, listing),
         {:ok, files} <- read_files(remote, config.repo, Enum.take(listing.files, @max_files)) do
      snapshot = %{
        config: config,
        branch: branch,
        account: account,
        can_push?: repo.can_push?,
        folder?: listing.folder?,
        checked_at: DateTime.utc_now(),
        files: files
      }

      if config() == {:ok, config} do
        merged? = check_prs(remote, config)
        linked? = link_pairs(snapshot)
        if merged? or linked?, do: Playbooks.broadcast_changed()
      end

      %{entries: entries} = State.build(snapshot, all_playbooks())
      {:ok, snapshot, listing, status(snapshot, entries)}
    end
  end

  defp fresh_listing(remote, config, branch, previous) do
    etag = previous && previous.branch == branch && previous.etag

    case list(remote, config, branch, etag || nil) do
      {:ok, :not_modified} ->
        {:ok, previous}

      {:ok, :no_folder} ->
        {:ok, %{config: config, branch: branch, etag: nil, folder?: false, files: []}}

      {:ok, %{etag: etag, files: files}} ->
        {:ok, %{config: config, branch: branch, etag: etag, folder?: true, files: files}}

      {:error, _} = error ->
        error
    end
  end

  defp list(remote, config, branch, etag) do
    case remote.list(config.repo, branch, config.folder, etag) do
      {:ok, %{files: files} = listing} ->
        files =
          files
          |> Enum.filter(&String.ends_with?(String.downcase(&1.path), ".md"))
          |> Enum.reject(&(String.downcase(Path.basename(&1.path)) == "readme.md"))
          |> Enum.sort_by(& &1.path)

        {:ok, %{listing | files: files}}

      other ->
        other
    end
  end

  # Uncached blobs are read 8 at a time. One blob gh couldn't read makes that
  # file unreadable; an auth or not-found answer fails the whole read.
  defp read_files(remote, repo, files) do
    files
    |> Task.async_stream(
      fn file ->
        read =
          if Remote.file_name_ok?(file.path) and Remote.sha_ok?(file.sha) and
               file.size <= State.max_file_bytes(),
             do: blob(remote, repo, file.sha),
             else: :skip

        {file, read}
      end,
      max_concurrency: 8,
      timeout: 35_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(files)
    |> Enum.reduce_while({:ok, []}, fn
      {{:ok, {_file, {:error, {kind, _}} = error}}, _}, _acc
      when kind in [:gh_missing, :gh_too_old, :gh_signed_out, :not_found] ->
        {:halt, error}

      {{:ok, {file, read}}, _}, {:ok, acc} ->
        {:cont, {:ok, [State.prepare_file(file, read) | acc]}}

      {{:exit, _}, file}, {:ok, acc} ->
        {:cont,
         {:ok, [State.prepare_file(file, {:error, {:gh_failed, "timed out reading it"}}) | acc]}}
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp blob(remote, repo, sha) do
    case Refresher.cached_blob(sha) do
      nil ->
        with {:ok, text} <- remote.read(repo, sha) do
          Refresher.cache_blob(sha, text)
          {:ok, text}
        end

      text ->
        {:ok, text}
    end
  end

  # Name pairs with equal content get linked, so the next edit on either side
  # reads as an edit or an update, with a base. Only rows still not linked
  # here are written; version and lock_version are left alone.
  defp link_pairs(snapshot) do
    %{links: links} = State.build(snapshot, all_playbooks())
    now = DateTime.utc_now()

    Enum.reduce(links, false, fn {playbook, file}, changed? ->
      {count, _} =
        Repo.update_all(
          from(p in Playbook,
            where: p.id == ^playbook.id,
            where:
              is_nil(p.origin_repo) or
                fragment("lower(?)", p.origin_repo) != ^String.downcase(snapshot.config.repo) or
                is_nil(p.origin_path) or p.origin_path != ^file.path
          ),
          set: [
            origin_repo: snapshot.config.repo,
            origin_path: file.path,
            origin_version: file.version,
            origin_sha: file.hash,
            origin_body: Text.strip_version(file.text),
            synced_at: now
          ]
        )

      changed? or count > 0
    end)
  end

  # Open export pull requests: a merged one becomes the origin, a closed one
  # is forgotten. Each write is guarded by the PR number it saw, so a newer
  # export's PR is never overwritten. Only PRs opened in this repo are
  # asked about: another repo's PR keeps waiting for its repo to come back.
  defp check_prs(remote, config) do
    now = DateTime.utc_now()

    Repo.all(from p in Playbook, where: not is_nil(p.pr_number))
    |> Enum.filter(&pr_in_repo?(&1, config.repo))
    |> Enum.reduce(false, fn playbook, changed? ->
      guard =
        from(p in Playbook, where: p.id == ^playbook.id and p.pr_number == ^playbook.pr_number)

      count =
        case remote.pr(config.repo, playbook.pr_number) do
          {:ok, :merged} ->
            Repo.update_all(guard,
              set:
                [
                  origin_repo: config.repo,
                  origin_path: playbook.pr_path,
                  origin_version: playbook.pr_version,
                  origin_sha: playbook.pr_sha,
                  origin_body: playbook.pr_body,
                  synced_at: now
                ] ++ clear_pr()
            )
            |> elem(0)

          {:ok, :closed} ->
            Repo.update_all(guard, set: clear_pr()) |> elem(0)

          _ ->
            0
        end

      changed? or count > 0
    end)
  end

  # GitHub's owner and repo names are case-insensitive
  defp pr_in_repo?(%Playbook{pr_url: url}, repo) when is_binary(url),
    do:
      String.starts_with?(
        String.downcase(url),
        "https://github.com/#{String.downcase(repo)}/pull/"
      )

  defp pr_in_repo?(_playbook, _repo), do: false

  defp clear_pr,
    do: [pr_number: nil, pr_url: nil, pr_path: nil, pr_version: nil, pr_sha: nil, pr_body: nil]

  # -- Compare ------------------------------------------------------------------

  @doc """
  Yours against GitHub's for an entry in the latest cached status (`key` is
  the entry's key): `:update`, `:both_changed`, `:name_clash`, and `:new`
  (only GitHub's side: `local` nil). A file that doesn't parse is
  `{:unreadable, reason}`, with the parse error. An unknown key, or no
  status, is `:stale`. Fetches the last commit touching the file, for
  `remote.by`/`at`. `base_version` is the version last synced, or nil.
  """
  def compare(key) do
    with {:ok, status} <- cached_or_stale(),
         {:ok, entry} <- find_entry(status, key),
         :ok <- comparable(entry),
         {:ok, remote_text} <- blob(Remote.impl(), status.config.repo, entry.sha) do
      remote = Remote.impl()

      {by, at} =
        case remote.last_commit(status.config.repo, status.branch, entry.path) do
          {:ok, %{by: by, at: at}} -> {by, at}
          _ -> {nil, nil}
        end

      playbook = entry.playbook
      linked? = playbook && State.linked_here?(playbook, status.config)
      base = if linked?, do: playbook.origin_body
      local_text = playbook && playbook.body

      parts =
        Compare.compare(local_text, remote_text, base,
          local_version: playbook && playbook.version,
          remote_version: entry.remote_version
        )

      {:ok, remote_def} = Canopy.Playbooks.Definition.parse(Text.strip_version(remote_text))

      local_side =
        if playbook do
          {:ok, local_def} = Playbooks.definition(playbook)
          %{version: playbook.version, definition: local_def, at: playbook.updated_at, by: nil}
        end

      {:ok,
       Map.merge(parts, %{
         entry: entry,
         local: local_side,
         remote: %{version: entry.remote_version, definition: remote_def, at: at, by: by},
         base_version: entry.base_version
       })}
    end
  end

  defp comparable(%{state: state}) when state in [:update, :both_changed, :name_clash, :new],
    do: :ok

  defp comparable(%{state: :unreadable, error: reason}), do: {:error, {:unreadable, reason}}
  defp comparable(entry), do: stale("#{entry.name} has nothing to compare")

  defp cached_or_stale do
    case cached_status() do
      {:ok, status} -> {:ok, status}
      nil -> stale("nothing has been read from GitHub yet")
    end
  end

  defp find_entry(status, key) do
    case Enum.find(status.entries, &(&1.key == key)) do
      nil -> stale("#{key} is no longer in the list")
      entry -> {:ok, entry}
    end
  end

  defp stale(text), do: {:error, {:stale, text}}

  # -- Import -------------------------------------------------------------------

  @doc """
  The free name Keep both (or a `:new` file whose name is taken) imports
  as: `<name>-2`, `<name>-3`, …, within 40 characters.
  """
  def copy_name(name) do
    State.copy_name(name, MapSet.new(Repo.all(from p in Playbook, select: p.name)))
  end

  @doc """
  Imports the entries the dialog showed, each with a choice: `:take` for a
  `:new` file (created, enabled; under `import_as` or a free copy name when
  its name is taken) or *Replace mine* on `:update`, `:both_changed` and
  `:name_clash`; `:keep_both` for `:both_changed` and `:name_clash` (GitHub's
  copy created as `<name>-2` and linked to the file; yours unlinked). All or
  nothing, in one transaction. A playbook edited since the entry was built
  (`lock_version`), or a choice the state doesn't allow, is `:stale`.
  Imports the blob the entry was built from (`entry.sha`), so you get what
  you saw. The undo token lasts 15 minutes.
  """
  def import(choices) when is_list(choices) do
    with {:ok, config} <- require_config(),
         {:ok, texts} <- fetch_texts(config, Enum.map(choices, &elem(&1, 0))) do
      fn ->
        taken = MapSet.new(Repo.all(from p in Playbook, select: p.name))

        {done, _taken} =
          Enum.map_reduce(choices, taken, fn {entry, choice}, taken ->
            import_one(entry, choice, texts[entry.sha], config, taken)
          end)

        done
      end
      |> Repo.transaction(mode: :immediate)
      |> case do
        {:ok, done} ->
          Playbooks.broadcast_changed()
          token = Refresher.put_undo(Enum.flat_map(done, & &1.undo))
          {:ok, %{playbooks: Enum.map(done, & &1.playbook), undo: token}}

        {:error, {kind, _} = error} when is_atom(kind) ->
          {:error, error}
      end
    end
  end

  defp require_config do
    case config() do
      {:ok, config} -> {:ok, config}
      :not_set_up -> {:error, {:not_set_up, "playbook sharing isn't set up"}}
    end
  end

  defp fetch_texts(config, entries) do
    remote = Remote.impl()

    entries
    |> Enum.map(& &1.sha)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn sha, {:ok, acc} ->
      cond do
        not Remote.sha_ok?(sha) ->
          {:halt, stale("an entry has no file to import")}

        true ->
          case blob(remote, config.repo, sha) do
            {:ok, text} -> {:cont, {:ok, Map.put(acc, sha, text)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp import_one(entry, choice, text, config, taken) do
    with :ok <- check_unchanged(entry) do
      case {entry.state, choice} do
        {:new, :take} ->
          wanted = entry.import_as || entry.name

          name =
            if MapSet.member?(taken, wanted), do: State.copy_name(entry.name, taken), else: wanted

          playbook = create_linked(name, text, entry, config)

          {%{playbook: playbook, undo: [{:created, playbook.id, playbook.lock_version}]},
           MapSet.put(taken, name)}

        {state, :take} when state in [:update, :both_changed, :name_clash] ->
          before = Repo.get!(Playbook, entry.playbook.id)
          playbook = replace(before, text, entry, config)
          {%{playbook: playbook, undo: [{:replaced, before, playbook.lock_version}]}, taken}

        {state, :keep_both} when state in [:both_changed, :name_clash] ->
          name = State.copy_name(entry.playbook.name, taken)
          copy = create_linked(name, text, entry, config)
          before = Repo.get!(Playbook, entry.playbook.id)
          Repo.update_all(from(p in Playbook, where: p.id == ^before.id), set: clear_origin())

          {%{
             playbook: copy,
             undo: [{:created, copy.id, copy.lock_version}, {:unlinked, before}]
           }, MapSet.put(taken, name)}

        {state, choice} ->
          Repo.rollback(
            {:stale, "#{entry.name} can't be imported that way (#{state}, #{choice})"}
          )
      end
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp check_unchanged(%{playbook: nil}), do: :ok

  defp check_unchanged(%{playbook: %Playbook{id: id, lock_version: seen, name: name}}) do
    case Repo.one(from p in Playbook, where: p.id == ^id, select: p.lock_version) do
      ^seen -> :ok
      nil -> {:error, {:stale, "#{name} was deleted since you looked"}}
      _ -> {:error, {:stale, "#{name} changed since you looked"}}
    end
  end

  defp origin_attrs(text, entry, config) do
    %{
      origin_repo: config.repo,
      origin_path: entry.path,
      origin_version: entry.remote_version,
      origin_sha: Text.content_hash(text),
      origin_body: Text.strip_version(text),
      synced_at: DateTime.utc_now()
    }
  end

  defp create_linked(name, text, entry, config) do
    attrs =
      Map.merge(origin_attrs(text, entry, config), %{
        body: Text.put_name(text, name),
        enabled: true,
        source: "user",
        version: entry.remote_version || 1
      })

    %Playbook{}
    |> Playbook.sharing_changeset(attrs)
    |> Repo.insert()
    |> or_rollback(name)
  end

  # Replacing an agent's draft claims it for the user, as editing it does,
  # so the agent's next save_draft can't overwrite the imported text
  defp replace(playbook, text, entry, config) do
    attrs =
      Map.merge(origin_attrs(text, entry, config), %{
        body: Text.put_name(text, playbook.name),
        version: entry.remote_version || playbook.version + 1,
        source: if(playbook.source == "agent", do: "user", else: playbook.source)
      })

    playbook
    |> Playbook.sharing_changeset(attrs)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(stale_error_field: :lock_version)
    |> or_rollback(playbook.name)
  end

  defp or_rollback({:ok, playbook}, _name), do: playbook

  defp or_rollback({:error, changeset}, name) do
    Repo.rollback({:stale, "#{name}: #{changeset_text(changeset)}"})
  end

  defp clear_origin,
    do: [
      origin_repo: nil,
      origin_path: nil,
      origin_version: nil,
      origin_sha: nil,
      origin_body: nil,
      synced_at: nil
    ]

  @origin_fields [
    :origin_repo,
    :origin_path,
    :origin_version,
    :origin_sha,
    :origin_body,
    :synced_at
  ]

  @doc """
  Undoes an import: created playbooks are deleted, replaced ones get their
  text, version and origin back, a Keep both original gets its origin back.
  All or nothing; a playbook edited since, or one with a run in progress, is
  `:stale`, and so is an expired (15 minutes) or unknown token.
  """
  def undo_import(token) do
    case Refresher.get_undo(token) do
      nil ->
        stale("undo expired")

      records ->
        fn -> Enum.each(records, &undo_one/1) end
        |> Repo.transaction(mode: :immediate)
        |> case do
          {:ok, _} ->
            Refresher.drop_undo(token)
            Playbooks.broadcast_changed()
            :ok

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp undo_one({:created, id, lock_version}) do
    case Repo.get(Playbook, id) do
      nil ->
        :ok

      %Playbook{lock_version: ^lock_version} = playbook ->
        live? =
          Repo.exists?(
            from r in Run, where: r.playbook_id == ^id and r.status in ^Run.live_statuses()
          )

        if live?, do: Repo.rollback({:stale, "#{playbook.name} has a run in progress"})
        Repo.delete!(playbook)

      playbook ->
        Repo.rollback({:stale, "#{playbook.name} changed since the import"})
    end
  end

  defp undo_one({:replaced, before, lock_version}) do
    {count, _} =
      Repo.update_all(
        from(p in Playbook, where: p.id == ^before.id and p.lock_version == ^lock_version),
        set:
          [
            body: before.body,
            name: before.name,
            description: before.description,
            version: before.version,
            updated_at: DateTime.utc_now()
          ] ++ Enum.map(@origin_fields, &{&1, Map.get(before, &1)}),
        inc: [lock_version: 1]
      )

    if count == 0, do: Repo.rollback({:stale, "#{before.name} changed since the import"})
  end

  defp undo_one({:unlinked, before}) do
    Repo.update_all(
      from(p in Playbook, where: p.id == ^before.id),
      set: Enum.map(@origin_fields, &{&1, Map.get(before, &1)})
    )
  end

  # -- Export -------------------------------------------------------------------

  @doc """
  Opens one pull request with the entries the dialog showed: each must be
  exportable (`:edited`, `:not_on_github`, `:both_changed`, `:name_clash`,
  with an `export_version`), its playbook enabled and unchanged since
  (`lock_version`), and its file on GitHub still the blob it was built from
  (`sha`), else `:stale`. Each file is written with `version:
  export_version`. On success each playbook records the PR (`In PR #n`) and
  its version rises to `export_version`; nothing else local changes.
  """
  def export(entries, %{title: title} = params) when is_list(entries) do
    remote = Remote.impl()

    with {:ok, config} <- require_config(),
         :ok <- if(entries == [], do: stale("nothing to export"), else: :ok),
         {:ok, repo} <- remote.repo(config.repo),
         :ok <- can_push(repo, config),
         branch = config.branch || repo.default_branch,
         :ok <- check_exportable(entries),
         {:ok, listing} <- list(remote, config, branch, nil),
         {:ok, files} <- export_files(remote, config, listing, entries) do
      pr_body = pr_body(params[:note] || params["note"], files)

      case remote.open_pr(
             config.repo,
             branch,
             pr_branch(params),
             Enum.map(files, &%{path: &1.path, content: &1.content}),
             title,
             pr_body
           ) do
        {:ok, pr} ->
          record_pr(files, pr)
          Playbooks.broadcast_changed()
          broadcast_cached()
          {:ok, pr}

        {:error, {kind, raw}}
        when kind in [:read_only, :gh_signed_out, :gh_missing, :gh_too_old] ->
          {:error, {kind, raw}}

        {:error, {_kind, raw}} ->
          {:error, {:pr_failed, raw}}
      end
    end
  end

  defp can_push(%{can_push?: true}, _config), do: :ok

  defp can_push(_repo, config),
    do: {:error, {:read_only, "your gh account can't push to #{config.repo}"}}

  defp export_error({:too_long, bytes}), do: "too long for GitHub by #{bytes} bytes"
  defp export_error(reason) when is_binary(reason), do: reason
  defp export_error(_), do: "can't be exported"

  defp check_exportable(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      cond do
        entry.state not in State.exportable() or is_nil(entry.playbook) ->
          {:halt, stale("#{entry.name} can't be exported now")}

        is_nil(entry.export_version) ->
          {:halt, stale("#{entry.name}: #{export_error(entry.error)}")}

        true ->
          case Repo.get(Playbook, entry.playbook.id) do
            %Playbook{enabled: true, lock_version: lv} when lv == entry.playbook.lock_version ->
              {:cont, :ok}

            %Playbook{enabled: false} ->
              {:halt, stale("#{entry.name} is disabled")}

            nil ->
              {:halt, stale("#{entry.name} was deleted since you looked")}

            _ ->
              {:halt, stale("#{entry.name} changed in Canopy since you looked")}
          end
      end
    end)
  end

  # Each file's path and text, checked against the listing just read: a file
  # that changed (or appeared) on GitHub since the entry was built is stale.
  defp export_files(remote, config, listing, entries) do
    shas =
      case listing do
        :no_folder -> %{}
        %{files: files} -> Map.new(files, &{&1.path, &1.sha})
      end

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      path = entry.path || Text.file_path(config.folder, entry.playbook.name)

      cond do
        not Remote.file_name_ok?(path) ->
          {:halt, stale("#{entry.name}: #{path} isn't a file name Canopy writes")}

        Map.get(shas, path) != entry.sha ->
          {:halt, stale("#{entry.name} changed on GitHub since you looked")}

        true ->
          remote_name =
            with sha when is_binary(sha) <- entry.sha,
                 {:ok, text} <- blob(remote, config.repo, sha),
                 [_, name] <- Regex.run(~r/^name:\s*(\S+)\s*$/m, text) do
              name
            else
              _ -> entry.playbook.name
            end

          stripped = Text.put_name(entry.playbook.body, remote_name)
          content = Text.put_version(stripped, entry.export_version)

          {:cont,
           {:ok,
            [
              %{
                entry: entry,
                path: path,
                content: content,
                body: stripped,
                version: entry.export_version
              }
              | acc
            ]}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp pr_body(note, files) do
    list = Enum.map_join(files, "\n", &"- `#{&1.path}` → v#{&1.version}")

    note =
      if is_binary(note) and String.trim(note) != "", do: String.trim(note) <> "\n\n", else: ""

    note <> "Playbooks:\n\n" <> list <> "\n\nExported from Canopy."
  end

  # Records the PR on each playbook, guarded by the PR number the entry saw
  # (another export may have got there first); raises the version without
  # touching lock_version, so an open editor isn't made stale.
  defp record_pr(files, pr) do
    for %{entry: entry, path: path, body: body, version: version} <- files do
      seen = entry.playbook.pr_number

      query =
        if seen,
          do: from(p in Playbook, where: p.id == ^entry.playbook.id and p.pr_number == ^seen),
          else: from(p in Playbook, where: p.id == ^entry.playbook.id and is_nil(p.pr_number))

      Repo.update_all(
        from(p in query,
          update: [
            set: [
              pr_number: ^pr.number,
              pr_url: ^pr.url,
              pr_path: ^path,
              pr_version: ^version,
              pr_sha: ^Text.content_hash(body),
              pr_body: ^body,
              version: fragment("max(?, ?)", p.version, ^version)
            ]
          ]
        ),
        []
      )
    end
  end

  defp broadcast_cached do
    case cached_status() do
      {:ok, status} -> broadcast({:playbook_sharing, :status, status})
      nil -> :ok
    end
  end

  @doc ~S|The branch an export opens: `"canopy/playbooks-1102-221405"`, in local time.|
  def branch_name(%DateTime{} = at) do
    {{_y, m, d}, {h, min, s}} =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    "canopy/playbooks-" <> pad(m) <> pad(d) <> "-" <> pad(h) <> pad(min) <> pad(s)
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # the branch the dialog showed (`branch`), so the footer names the one used
  defp pr_branch(params) do
    with "canopy/playbooks-" <> _ = branch <- params[:branch] || params["branch"],
         true <- Canopy.GitHub.valid_ref?(branch) do
      branch
    else
      _ -> branch_name(DateTime.utc_now())
    end
  end

  # -- PubSub -------------------------------------------------------------------

  @doc "Subscribe to the sharing topic."
  def subscribe, do: Phoenix.PubSub.subscribe(Canopy.PubSub, @topic)

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Canopy.PubSub, @topic, message)
end
