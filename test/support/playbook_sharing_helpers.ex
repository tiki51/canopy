defmodule Canopy.PlaybookSharingHelpers do
  @moduledoc """
  Playbook sharing in tests, without gh: `configure_sharing/1` saves the
  settings, `stub_remote/2` describes the shared folder (an in-memory
  `Canopy.Playbooks.Sharing.FakeRemote`), `link_playbook/4` makes a local
  playbook follow a file as an import would. Tests that use them are
  `async: false` (the fake and the Refresher are global).
  """

  import Ecto.Query

  alias Canopy.Playbooks.Playbook
  alias Canopy.Playbooks.Sharing
  alias Canopy.Playbooks.Sharing.{FakeRemote, Refresher, Text}
  alias Canopy.Repo

  @repo "acme/playbooks"

  @doc """
  Saves the sharing settings: repo `acme/playbooks`, the default branch,
  folder `playbooks`, with `attrs` (`repo`, `branch`, `folder`) over them.
  Returns the config.
  """
  def configure_sharing(attrs \\ %{}) do
    attrs = Map.merge(%{repo: @repo, branch: nil, folder: "playbooks"}, Map.new(attrs))
    {:ok, config} = Sharing.save_config(attrs)
    config
  end

  @doc """
  Replaces the fake repository with `files` and forgets any cached status.

  `files`: `%{"bug-fix" => body}` (the file `<folder>/bug-fix.md`) or
  `%{"playbooks/x.md" => body}` (a path). Options:
  - `can_push?:` (true), `account:` ("sbarber"), `default_branch:` ("main");
  - `versions: %{"bug-fix" => 4}` writes `version: 4` into that file;
  - `prs: [%{number: 14, state: :open | :merged | :closed}]`;
  - `fail: [account: :gh_signed_out]`: that callback returns that error kind;
  - `no_folder: true`: the folder doesn't exist.
  """
  def stub_remote(files, opts \\ []) do
    folder =
      case Sharing.config() do
        {:ok, %{folder: folder}} -> folder
        :not_set_up -> "playbooks"
      end

    versions = Map.new(Keyword.get(opts, :versions, %{}), fn {k, v} -> {path(k, folder), v} end)

    files =
      Map.new(files, fn {key, body} ->
        path = path(key, folder)

        body =
          case versions[path] do
            nil -> body
            n -> Text.put_version(body, n)
          end

        {path, body}
      end)

    prs =
      opts
      |> Keyword.get(:prs, [])
      |> Map.new(fn pr ->
        {pr.number,
         Map.merge(
           %{title: "PR #{pr.number}", body: "", base: "main", branch: "canopy/x", files: []},
           Map.put_new(pr, :state, :open)
         )}
      end)

    FakeRemote.load(%{
      files: files,
      folder: folder,
      no_folder: Keyword.get(opts, :no_folder, false),
      can_push?: Keyword.get(opts, :can_push?, true),
      account: Keyword.get(opts, :account, "sbarber"),
      default_branch: Keyword.get(opts, :default_branch, "main"),
      prs: prs,
      fail: Map.new(Keyword.get(opts, :fail, []))
    })

    Refresher.reset()
    :ok
  end

  @doc """
  Makes `playbook` follow the file at `path` as an import of `body` (the text
  at that sync) at `version` would; returns the reloaded playbook.
  """
  def link_playbook(%Playbook{id: id}, path, version, body) do
    repo =
      case Sharing.config() do
        {:ok, %{repo: repo}} -> repo
        :not_set_up -> @repo
      end

    Repo.update_all(from(p in Playbook, where: p.id == ^id),
      set: [
        origin_repo: repo,
        origin_path: path,
        origin_version: version,
        origin_sha: Text.content_hash(body),
        origin_body: Text.strip_version(body),
        synced_at: DateTime.utc_now()
      ]
    )

    Repo.get!(Playbook, id)
  end

  @doc "A playbook text named `name`, with one step per id in `steps` (default `[\"work\"]`)."
  def playbook_text(name, opts \\ []) do
    description = Keyword.get(opts, :description, "Does #{name}.")
    steps = Keyword.get(opts, :steps, ["work"])
    guidance = Keyword.get(opts, :guidance, "Work carefully.")
    instructions = Keyword.get(opts, :instructions, %{})

    step_lines =
      Enum.map_join(steps, "\n", fn id ->
        "  - id: #{id}\n    title: #{String.capitalize(id)}\n    owner: coordinator"
      end)

    sections =
      Enum.map_join(steps, "\n", fn id ->
        "\n## #{id}\n\n#{Map.get(instructions, id, "Do #{id}.")}\n"
      end)

    """
    ---
    name: #{name}
    description: #{description}
    steps:
    #{step_lines}
    ---

    #{guidance}
    #{sections}\
    """
  end

  defp path(key, folder) do
    if String.ends_with?(key, ".md"), do: key, else: Text.file_path(folder, key)
  end
end
