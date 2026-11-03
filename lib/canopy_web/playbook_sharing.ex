defmodule CanopyWeb.PlaybookSharing do
  @moduledoc """
  What the Playbooks page shows about sharing through GitHub, without the
  LiveView: which section of the Import and Export dialogs each entry goes
  in, what starts ticked, the library chips, the updates count, the pull
  request's title, and the copy for each error.

  Entries come from `Canopy.Playbooks.Sharing.status/1`; every state,
  version and name is the backend's. Nothing here computes a state.
  """

  alias Canopy.Playbooks.Sharing.State

  # the states an export can write, given an `export_version`
  @exportable [:edited, :not_on_github, :both_changed, :name_clash]

  # what the badge and the notice count: each has a chip in the library
  @counted [:update, :both_changed, :name_clash]

  @doc """
  The Import dialog's sections: `ready` (`:new`, `:update`), `look`
  (`:both_changed`, `:name_clash`), `cant` (`:unreadable`) and `up_to_date`
  (`:up_to_date`, `:edited`, `:in_pr`). `:not_on_github` and `:name_taken`
  aren't listed.
  """
  def import_groups(entries) do
    groups = Enum.group_by(entries, &import_group/1)

    %{
      ready: Map.get(groups, :ready, []),
      look: Map.get(groups, :look, []),
      cant: Map.get(groups, :cant, []),
      up_to_date: Map.get(groups, :up_to_date, [])
    }
  end

  defp import_group(%{state: state}) when state in [:new, :update], do: :ready
  defp import_group(%{state: state}) when state in [:both_changed, :name_clash], do: :look
  defp import_group(%{state: :unreadable}), do: :cant
  defp import_group(%{state: state}) when state in [:up_to_date, :edited, :in_pr], do: :up_to_date
  defp import_group(_entry), do: nil

  @doc """
  The Export dialog's sections: `changed` (`:edited` first, as they start
  ticked, then `:not_on_github`, then `:both_changed` and `:name_clash`,
  each with an `export_version`; by name within each), `cant` (`:update`,
  `:name_taken`, and an exportable state without an `export_version`) and
  `up_to_date` (`:up_to_date`, `:in_pr`). Disabled playbooks are left out:
  drafts aren't exported.
  """
  def export_groups(entries) do
    entries = Enum.reject(entries, &draft?/1)
    groups = Enum.group_by(entries, &export_group/1)

    %{
      changed: Enum.sort_by(Map.get(groups, :changed, []), &export_rank(&1.state)),
      cant: Map.get(groups, :cant, []),
      up_to_date: Map.get(groups, :up_to_date, [])
    }
  end

  defp export_group(%{state: state} = entry) when state in @exportable,
    do: if(entry.export_version, do: :changed, else: :cant)

  defp export_group(%{state: state}) when state in [:update, :name_taken], do: :cant
  defp export_group(%{state: state}) when state in [:up_to_date, :in_pr], do: :up_to_date
  defp export_group(_entry), do: nil

  defp export_rank(:edited), do: 0
  defp export_rank(:not_on_github), do: 1
  defp export_rank(_look), do: 2

  defp draft?(%{playbook: %{enabled: false}}), do: true
  defp draft?(_entry), do: false

  @doc """
  The names an import of the ticked rows gives out, by key: a `:new` row
  under its `import_as` (or its name), Keep both under a copy name. Names
  are given in the order `Sharing.import/1` takes the rows (Ready, then
  Needs a look), each against `taken` (the library's names) plus those
  before it, so `bug-fix-2` arriving as new makes Keep both `bug-fix-3`.
  """
  def import_names(groups, picks, choices, taken) do
    ready = for entry <- groups.ready, MapSet.member?(picks, entry.key), do: {entry, :take}

    look =
      for entry <- groups.look,
          MapSet.member?(picks, entry.key),
          choice = choices[entry.key],
          do: {entry, choice.choice}

    {names, _taken} =
      Enum.flat_map_reduce(ready ++ look, taken, fn
        {%{state: :new} = entry, :take}, taken ->
          wanted = entry.import_as || entry.name

          name =
            if MapSet.member?(taken, wanted),
              do: State.copy_name(entry.name, taken),
              else: wanted

          {[{entry.key, name}], MapSet.put(taken, name)}

        {entry, :keep_both}, taken ->
          name = State.copy_name(entry.playbook.name, taken)
          {[{entry.key, name}], MapSet.put(taken, name)}

        _replace, taken ->
          {[], taken}
      end)

    Map.new(names)
  end

  @doc """
  Whether an entry has a checkbox in the dialog. Import: Ready rows, and
  Needs-a-look rows once a choice is made (the LiveView checks that).
  Export: the Changed in Canopy rows.
  """
  def tickable?(entry, :import), do: import_group(entry) in [:ready, :look]
  def tickable?(entry, :export), do: !draft?(entry) and export_group(entry) == :changed

  @doc """
  The keys ticked when a dialog opens. Import ticks every Ready row. Export
  ticks only `:edited` rows: export publishes to a shared repository, so a
  playbook that was never there (a starter included) is opt-in.
  """
  def default_ticks(entries, :import) do
    for %{state: state, key: key} <- entries,
        state in [:new, :update],
        into: MapSet.new(),
        do: key
  end

  def default_ticks(entries, :export) do
    for %{state: :edited, key: key} = entry <- entries,
        entry.export_version,
        !draft?(entry),
        into: MapSet.new(),
        do: key
  end

  @doc "How many updates the GitHub badge and the library notice announce (nil status: 0)."
  def update_count(nil), do: 0
  def update_count(%{entries: entries}), do: Enum.count(entries, &(&1.state in @counted))

  @doc """
  The pull request's title from the ticked entries:
  `Update feature-build (v7), add site-docs-refresh (v1)`. More than three
  read `Update 5 playbooks` (`Add 5 playbooks` when every one is new). No
  ticks: `""`.
  """
  def pr_title([]), do: ""

  def pr_title(entries) when length(entries) > 3 do
    verb = if Enum.all?(entries, &(&1.state == :not_on_github)), do: "Add", else: "Update"
    "#{verb} #{length(entries)} playbooks"
  end

  def pr_title(entries) do
    entries
    |> Enum.map_join(", ", fn entry ->
      verb = if entry.state == :not_on_github, do: "add", else: "update"
      "#{verb} #{entry.name}#{version_suffix(entry.export_version)}"
    end)
    |> capitalize_first()
  end

  defp version_suffix(nil), do: ""
  defp version_suffix(n), do: " (v#{n})"

  defp capitalize_first(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest

  @doc """
  The library chip for an entry, or nil: `%{label, class, state}`. Only
  `:update`, `:both_changed`, `:name_clash` and `:in_pr` have one; Export
  lists the rest.
  """
  def chip(%{state: :update} = entry),
    do: %{
      state: :update,
      label: "⤓ Update" <> versions(entry.local_version, entry.remote_version),
      class: "badge-secondary badge-soft"
    }

  def chip(%{state: :both_changed}),
    do: %{state: :both_changed, label: "⚠ Both changed", class: "badge-warning badge-soft"}

  def chip(%{state: :name_clash}),
    do: %{state: :name_clash, label: "⚠ Same name, different", class: "badge-warning badge-soft"}

  def chip(%{state: :in_pr, pr: %{number: number}}),
    do: %{state: :in_pr, label: "In PR ##{number}", class: "badge-ghost"}

  def chip(_entry), do: nil

  @doc "` · v3 → v4`, or less when a side has no number."
  def versions(nil, nil), do: ""
  def versions(nil, to), do: " · v#{to}"
  def versions(from, nil), do: " · v#{from}"
  def versions(from, to), do: " · v#{from} → v#{to}"

  @doc """
  The copy for an error box: `{tone, lead, next}`, tone one of `:error`,
  `:warning` or `:info`. `ctx` may carry `repo`, `account`, `folder` and
  `branch` for the words, `check` for the button the copy names (Settings'
  is Check connection; the dialogs' Check again) and `mode` (`:export` for
  Export's empty folder). `:not_set_up` has no box (nil): the dialog shows
  the setup fields instead. `:empty_folder` isn't an error kind; it's the
  box for `folder?: false`.
  """
  def error_copy(kind, ctx \\ %{})

  def error_copy(:not_set_up, _ctx), do: nil

  def error_copy(:gh_missing, ctx),
    do:
      {:error, "GitHub CLI not found",
       "Canopy reaches GitHub through gh. Install it with `brew install gh`, run `gh auth login`, then #{check(ctx)}."}

  def error_copy(:gh_signed_out, ctx),
    do: {:error, "gh isn't signed in", "Run `gh auth login` in a terminal, then #{check(ctx)}."}

  def error_copy(:gh_too_old, ctx),
    do: {:error, "gh is too old", "Update it with `brew upgrade gh`, then #{check(ctx)}."}

  def error_copy(:not_found, ctx) do
    who = if ctx[:account], do: ctx[:account], else: "your gh account"

    {:error, "Can't see #{ctx[:repo] || "that repository"}",
     "Check the name, or ask the owner to give #{who} access. Private repos work once you have access."}
  end

  def error_copy(:read_only, ctx),
    do:
      {:warning, "Import only: you can't push to this repo",
       "You can import from #{ctx[:repo] || "it"}, but exporting needs write access. Export stays disabled until you have it."}

  def error_copy(:empty_folder, ctx) do
    {:info, "#{folder_label(ctx[:folder])} is empty on #{ctx[:branch] || "the default branch"}",
     if(ctx[:mode] == :export,
       do: "Nothing on GitHub yet. Tick the playbooks to share; this export creates the folder.",
       else:
         "Nothing to import yet. Export some playbooks to start it; the first export creates the folder."
     )}
  end

  def error_copy(:unreadable, _ctx),
    do:
      {:error, "Can't read this file",
       "Fix it on GitHub; until then it's listed under Can't import."}

  def error_copy(:pr_failed, _ctx),
    do:
      {:error, "Couldn't open the pull request",
       "Nothing in your library changed. Try again; if it repeats, check `gh auth status`."}

  def error_copy(:stale, _ctx),
    do:
      {:warning, "Something changed while this was open",
       "The list is up to date again; check your picks and try again."}

  def error_copy(_gh_failed, _ctx),
    do: {:error, "GitHub didn't answer", "Try again in a moment."}

  defp check(ctx), do: ctx[:check] || "Check again"

  @doc """
  Why an exportable entry can't be exported, after the row's lead:
  `{:too_long, 5311}` → `5,311 bytes over the limit.`
  """
  def export_error({:too_long, bytes}), do: "#{thousands(bytes)} bytes over the limit."
  def export_error(reason) when is_binary(reason), do: reason <> "."
  def export_error(_reason), do: "It can't be exported."

  defp thousands(n) when n >= 1000, do: "#{thousands(div(n, 1000))},#{pad3(rem(n, 1000))}"
  defp thousands(n), do: Integer.to_string(n)

  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  @doc """
  A DOM id fragment for an entry's key: `playbooks/bug-fix.md` →
  `playbooks-bug-fix-md`, `local:<id>` → `local-<id>`.
  """
  def dom_id(key), do: String.replace(key, ~r/[^A-Za-z0-9_-]+/, "-")

  @doc "`playbooks/`, or `The repository root` for an empty folder."
  def folder_label(folder) when folder in [nil, ""], do: "The repository root"
  def folder_label(folder), do: folder <> "/"

  @doc """
  The GitHub address of the shared folder: `tree/<branch>/<folder>` once a
  status knows the branch, else the repository.
  """
  def repo_url(%{repo: repo} = config, branch) do
    base = "https://github.com/" <> repo

    case {branch, config[:folder]} do
      {nil, _} -> base
      {branch, folder} when folder in [nil, ""] -> "#{base}/tree/#{branch}"
      {branch, folder} -> "#{base}/tree/#{branch}/#{folder}"
    end
  end

  @doc """
  A pasted github.com address in the repository field fills all three
  fields (`repo`, `branch`, `folder`), through
  `Sharing.parse_location/1`. Anything else is left as typed.
  """
  def fill_from_url(%{"repo" => repo} = params) when is_binary(repo) do
    with true <- String.contains?(repo, "github.com"),
         %{repo: parsed} = location <- Canopy.Playbooks.Sharing.parse_location(String.trim(repo)) do
      params
      |> Map.put("repo", parsed)
      |> Map.put("branch", location.branch || params["branch"] || "")
      |> Map.put("folder", location.folder || params["folder"] || "")
    else
      _ -> params
    end
  end

  def fill_from_url(params), do: params

  @doc """
  The config `Sharing.check/1` takes, from the form's unsaved values.
  """
  def check_config(params) do
    %{
      repo: String.trim(params["repo"] || ""),
      branch: blank_nil(params["branch"]),
      folder: params["folder"] |> to_string() |> String.trim() |> String.trim("/")
    }
  end

  defp blank_nil(nil), do: nil

  defp blank_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  @doc "Whether a linked playbook's text differs from the GitHub copy it last synced."
  def edited_since?(%{origin_sha: sha, body: body}) when is_binary(sha),
    do: Canopy.Playbooks.Sharing.Text.content_hash(body) != sha

  def edited_since?(_playbook), do: false

  @doc """
  The line under a playbook's name: `v7 · from tiki51/canopy-playbooks (v5)
  · edited since`. `edited?` says whether the text differs from the copy it
  last synced. Without an origin, just the version.
  """
  def version_line(playbook, edited?) do
    origin =
      case playbook do
        %{origin_repo: repo} when is_binary(repo) ->
          " · from #{repo}#{if playbook.origin_version, do: " (v#{playbook.origin_version})"}" <>
            if(edited?, do: " · edited since", else: "")

        _ ->
          ""
      end

    "v#{playbook.version}" <> origin
  end
end
