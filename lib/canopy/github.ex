defmodule Canopy.GitHub do
  @moduledoc """
  Reading GitHub for watches (`Canopy.Watches`). Canopy stores no token and
  makes no network calls of its own: the implementation, `Canopy.GitHub.CLI`,
  shells out to the user's authenticated `gh` with fixed argv (never through
  a shell) and read-only REST calls. Tests swap in a Mox double
  (`config :canopy, :github, client: ...`).

  A check is a conditional request: with the ETag from the last 200, GitHub
  answers 304 Not Modified when nothing changed, which costs no rate limit.
  The paths and the item shape live here, pure, so any future push source
  (webhooks) produces the same items.

  An item is `%{key, title, url}` plus what filters read: `branch`, `labels`,
  `workflow`. Keys: `pr:<number>`, `issue:<number>`, `run:<id>`,
  `release:<tag>`, `commit:<sha>`.
  """

  @type check :: %{required(String.t()) => String.t() | nil}
  @type item :: %{
          key: String.t(),
          title: String.t() | nil,
          url: String.t() | nil,
          branch: String.t() | nil,
          labels: [String.t()],
          workflow: String.t() | nil
        }
  @type probe ::
          {:ok, :not_modified}
          | {:ok,
             %{
               etag: String.t() | nil,
               items: [item()],
               next?: boolean(),
               poll_interval: integer() | nil
             }}
          | {:error, String.t()}

  @doc """
  One conditional read of the first page of a check's REST path; `etag` nil
  for a full read. `next?` says whether GitHub has a further page.
  """
  @callback probe(check(), etag :: String.t() | nil) :: probe()

  @doc "A plain read of page `n` (2, 3, …) of a check's REST path."
  @callback page(check(), n :: pos_integer()) ::
              {:ok, %{items: [item()], next?: boolean()}} | {:error, String.t()}

  @doc "The repository's default branch, for a commits watch that names none."
  @callback default_branch(repo :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "The `owner/name` of the GitHub repository a local checkout points at."
  @callback resolve_repo(repo_path :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Whether `gh` is installed, its version, and whether it is logged in."
  @callback status() :: {:ok, map()} | {:error, String.t()}

  @sources ~w(prs issues ci_failures releases commits)

  def sources, do: @sources

  @doc "The configured implementation."
  def client, do: Application.get_env(:canopy, :github, [])[:client] || Canopy.GitHub.CLI

  def probe(check, etag), do: client().probe(check, etag)
  def page(check, n), do: client().page(check, n)
  def default_branch(repo), do: client().default_branch(repo)
  def resolve_repo(path), do: client().resolve_repo(path)
  def status, do: client().status()

  @repo_regex ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @ref_regex ~r/\A[A-Za-z0-9_.\/-]{1,200}\z/
  @file_regex ~r/\A[A-Za-z0-9_.-]{1,100}\.ya?ml\z/

  @doc "Whether `repo` is a plausible `owner/name`."
  def valid_repo?(repo), do: is_binary(repo) and Regex.match?(@repo_regex, repo)

  @doc """
  Checks the parts of a check an agent supplies; they are passed to `gh` as
  one argv element each, URL-encoded into the path, never through a shell.
  """
  def validate(%{"source" => source} = check) do
    cond do
      source not in @sources ->
        {:error, "source must be one of " <> Enum.join(@sources, ", ")}

      not valid_repo?(check["repo"]) ->
        {:error, "repo must be owner/name"}

      check["branch"] && not Regex.match?(@ref_regex, check["branch"]) ->
        {:error, "branch has characters a branch name cannot"}

      check["label"] && String.length(check["label"]) > 100 ->
        {:error, "label is too long"}

      check["workflow_file"] && source != "ci_failures" ->
        {:error, "workflow_file is only for ci_failures"}

      check["workflow_file"] && not Regex.match?(@file_regex, check["workflow_file"]) ->
        {:error, "workflow_file must be a file name like ci.yml"}

      check["label"] && source not in ["prs", "issues"] ->
        {:error, "label is only for prs and issues"}

      check["branch"] && source not in ["prs", "ci_failures", "commits"] ->
        {:error, "branch is only for prs (the base branch), ci_failures, and commits"}

      true ->
        :ok
    end
  end

  @doc "The REST path (with its query) a check reads; `page` above 1 asks for that page."
  def path(%{"source" => source, "repo" => repo} = check, page \\ 1) do
    {base, query} =
      case source do
        "prs" ->
          {"repos/#{repo}/pulls",
           [
             state: "open",
             sort: "created",
             direction: "desc",
             per_page: 50,
             base: check["branch"]
           ]}

        "issues" ->
          {"repos/#{repo}/issues",
           [
             state: "open",
             sort: "created",
             direction: "desc",
             per_page: 50,
             labels: check["label"]
           ]}

        "ci_failures" ->
          base =
            case check["workflow_file"] do
              nil -> "repos/#{repo}/actions/runs"
              file -> "repos/#{repo}/actions/workflows/#{file}/runs"
            end

          {base, [status: "failure", per_page: 30, branch: check["branch"]]}

        "releases" ->
          {"repos/#{repo}/releases", [per_page: 30]}

        "commits" ->
          {"repos/#{repo}/commits", [per_page: 30, sha: check["branch"]]}
      end

    query =
      (query ++ [page: if(page > 1, do: page)])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> URI.encode_query()

    base <> "?" <> query
  end

  @doc """
  A check with nothing but what it asks GitHub for, so two checks asking the
  same thing compare equal.
  """
  def normalize(check) do
    check
    |> Map.take(~w(source repo branch label workflow_file))
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  @doc "The items in a REST response for a check, newest first, filtered by it."
  def items(%{"source" => source} = check, json) do
    json
    |> raw_items(source)
    |> Enum.flat_map(&List.wrap(item(source, &1, check)))
    |> Enum.filter(&matches?(check, &1))
  end

  defp raw_items(%{"workflow_runs" => runs}, "ci_failures") when is_list(runs), do: runs
  defp raw_items(list, _source) when is_list(list), do: list
  defp raw_items(_json, _source), do: []

  defp item("prs", %{"number" => n} = pr, _check) do
    %{
      key: "pr:#{n}",
      title: pr["title"],
      url: pr["html_url"],
      author: get_in(pr, ["user", "login"]),
      branch: get_in(pr, ["base", "ref"]),
      labels: label_names(pr["labels"]),
      workflow: nil
    }
  end

  # the issues endpoint lists pull requests too
  defp item("issues", %{"pull_request" => _}, _check), do: nil

  defp item("issues", %{"number" => n} = issue, _check) do
    %{
      key: "issue:#{n}",
      title: issue["title"],
      url: issue["html_url"],
      author: get_in(issue, ["user", "login"]),
      branch: nil,
      labels: label_names(issue["labels"]),
      workflow: nil
    }
  end

  defp item("ci_failures", %{"id" => id} = run, _check) do
    title =
      [run["name"], run["display_title"]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(": ")

    %{
      key: "run:#{id}",
      title: title,
      url: run["html_url"],
      author: get_in(run, ["actor", "login"]),
      branch: run["head_branch"],
      labels: [],
      workflow: run["path"]
    }
  end

  defp item("releases", %{"draft" => true}, _check), do: nil

  defp item("releases", %{"tag_name" => tag} = release, _check) do
    %{
      key: "release:#{tag}",
      title: release["name"] || tag,
      url: release["html_url"],
      author: get_in(release, ["author", "login"]),
      branch: nil,
      labels: [],
      workflow: nil
    }
  end

  # the commits endpoint says nothing about branches: the one asked for it is
  defp item("commits", %{"sha" => sha} = commit, check) do
    message = get_in(commit, ["commit", "message"]) || ""

    %{
      key: "commit:#{sha}",
      title: message |> String.split("\n") |> hd(),
      url: commit["html_url"],
      author: get_in(commit, ["author", "login"]) || get_in(commit, ["commit", "author", "name"]),
      branch: check["branch"],
      labels: [],
      workflow: nil
    }
  end

  defp item(_source, _raw, _check), do: nil

  defp label_names(labels) when is_list(labels),
    do: Enum.flat_map(labels, fn l -> List.wrap(l["name"]) end)

  defp label_names(_), do: []

  @doc """
  Whether an item passes a check's filters: the same filters the REST path
  asks for, applied again so items from any source (a poll for another
  watch, a future webhook) can be handed to every watch on the repository.
  """
  def matches?(check, item) do
    branch_ok?(check, item) and label_ok?(check, item) and workflow_ok?(check, item)
  end

  defp branch_ok?(%{"branch" => branch}, item) when is_binary(branch), do: item[:branch] == branch
  defp branch_ok?(_check, _item), do: true

  defp label_ok?(%{"label" => label}, item) when is_binary(label),
    do: Enum.any?(item[:labels] || [], &(String.downcase(&1) == String.downcase(label)))

  defp label_ok?(_check, _item), do: true

  defp workflow_ok?(%{"workflow_file" => file}, item) when is_binary(file),
    do: is_binary(item[:workflow]) and Path.basename(item[:workflow]) == file

  defp workflow_ok?(_check, _item), do: true

  @doc "What a watch looks for, in words: \"failed CI on main in owner/repo\"."
  def describe(%{"source" => source} = check) do
    what =
      case source do
        "prs" -> "new pull requests" <> on(check["branch"], " into ") <> labelled(check)
        "issues" -> "new issues" <> labelled(check)
        "ci_failures" -> "failed CI" <> workflow(check) <> on(check["branch"], " on ")
        "releases" -> "new releases"
        "commits" -> "new commits" <> on(check["branch"], " on ")
        other -> other
      end

    what <> " in " <> to_string(check["repo"])
  end

  def describe(_), do: "GitHub"

  defp on(nil, _word), do: ""
  defp on(branch, word), do: word <> branch

  defp labelled(%{"label" => label}) when is_binary(label), do: " labelled #{label}"
  defp labelled(_), do: ""

  defp workflow(%{"workflow_file" => file}) when is_binary(file), do: " in #{file}"
  defp workflow(_), do: ""
end
