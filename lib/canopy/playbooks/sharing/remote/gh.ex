defmodule Canopy.Playbooks.Sharing.Remote.GH do
  @moduledoc """
  `Canopy.Playbooks.Sharing.Remote` through the user's `gh`, with
  `Canopy.GitHub.CLI.api/3`. Reads use the REST contents and git blob APIs;
  `open_pr/6` writes through the git data API (no clone, no working copy).

  Every path segment built from remote data has already passed
  `Remote.file_name_ok?/1` or `Remote.sha_ok?/1`, the branch
  `Canopy.GitHub.valid_ref?/1` and the folder the settings' folder rule.
  """

  @behaviour Canopy.Playbooks.Sharing.Remote

  alias Canopy.GitHub.CLI

  @permission ~r/not accessible|push access|permission|denied|must have admin/i

  @impl true
  def account do
    case CLI.status() do
      {:ok, %{too_old?: true, version: version}} ->
        {:error, {:gh_too_old, "gh version #{version} is too old; Canopy needs gh 2.0 or later"}}

      {:ok, %{logged_in?: false, detail: detail}} ->
        {:error, {:gh_signed_out, detail}}

      {:ok, %{account: account}} when is_binary(account) ->
        {:ok, account}

      {:ok, _} ->
        # signed in, but this gh words `auth status` differently: ask GitHub
        case get_json("user") do
          {:ok, %{"login" => login}} when is_binary(login) -> {:ok, login}
          {:ok, _} -> {:error, {:gh_failed, "GitHub didn't say which account gh uses"}}
          error -> read_error(error)
        end

      {:error, text} ->
        if text =~ "not installed",
          do: {:error, {:gh_missing, text}},
          else: {:error, {:gh_failed, text}}
    end
  end

  @impl true
  def repo(repo) do
    case get_json("repos/#{repo}") do
      {:ok, %{"default_branch" => branch} = json} when is_binary(branch) ->
        {:ok, %{default_branch: branch, can_push?: get_in(json, ["permissions", "push"]) == true}}

      {:ok, _} ->
        {:error, {:gh_failed, "GitHub did not say which branch #{repo} defaults to"}}

      error ->
        read_error(error)
    end
  end

  @impl true
  def list(repo, branch, folder, etag) do
    path = "repos/#{repo}/contents" <> if(folder in [nil, ""], do: "", else: "/" <> folder)

    case CLI.api("GET", path, query: [ref: branch], etag: etag) do
      {:ok, 304, _headers, _body} ->
        {:ok, :not_modified}

      {:ok, _, headers, body} ->
        case decode(body) do
          {:ok, []} ->
            {:ok, :no_folder}

          {:ok, entries} when is_list(entries) ->
            files =
              for %{"type" => "file", "path" => p, "sha" => sha, "size" => size} <- entries,
                  is_binary(p) and is_integer(size),
                  do: %{path: p, sha: sha, size: size}

            {:ok, %{etag: headers["etag"], files: files}}

          # the folder is a file
          {:ok, _} ->
            {:ok, :no_folder}

          error ->
            read_error(error)
        end

      {:error, {:http, 404, _}} ->
        case get_json("repos/#{repo}/branches/#{segments(branch)}") do
          {:ok, _} -> {:ok, :no_folder}
          {:error, {:http, 404, _}} -> {:error, {:not_found, "branch #{branch} not found"}}
          error -> read_error(error)
        end

      error ->
        read_error(error)
    end
  end

  @impl true
  def read(repo, sha) do
    with {:ok, %{"content" => content} = json} <- get_json("repos/#{repo}/git/blobs/#{sha}"),
         {:ok, text} <- blob_text(json["encoding"], content) do
      if String.valid?(text),
        do: {:ok, text},
        else: {:error, {:gh_failed, "the file isn't UTF-8 text"}}
    else
      :error -> {:error, {:gh_failed, "GitHub sent a blob Canopy couldn't decode"}}
      {:ok, _} -> {:error, {:gh_failed, "GitHub sent a blob without content"}}
      error -> read_error(error)
    end
  end

  defp blob_text("base64", content) when is_binary(content),
    do: content |> String.replace(~r/\s/, "") |> Base.decode64()

  defp blob_text(_utf8, content) when is_binary(content), do: {:ok, content}
  defp blob_text(_, _), do: :error

  @impl true
  def last_commit(repo, branch, path) do
    case get_json("repos/#{repo}/commits", query: [sha: branch, path: path, per_page: 1]) do
      {:ok, [commit | _]} ->
        by = get_in(commit, ["author", "login"]) || get_in(commit, ["commit", "author", "name"])

        at =
          case DateTime.from_iso8601(get_in(commit, ["commit", "author", "date"]) || "") do
            {:ok, at, _} -> at
            _ -> nil
          end

        {:ok, %{by: by, at: at}}

      {:ok, _} ->
        {:ok, %{by: nil, at: nil}}

      error ->
        read_error(error)
    end
  end

  @impl true
  def pr(repo, number) do
    case get_json("repos/#{repo}/pulls/#{number}") do
      {:ok, %{"merged" => true}} -> {:ok, :merged}
      {:ok, %{"state" => "closed"}} -> {:ok, :closed}
      {:ok, %{"state" => _}} -> {:ok, :open}
      {:ok, _} -> {:error, {:gh_failed, "GitHub sent a pull request without a state"}}
      error -> read_error(error)
    end
  end

  # -- Opening a pull request --------------------------------------------------------

  @impl true
  def open_pr(repo, base, branch, files, title, body) do
    with {:ok, %{"object" => %{"sha" => base_sha}}} <-
           get_json("repos/#{repo}/git/ref/heads/#{segments(base)}") |> step(),
         {:ok, %{"tree" => %{"sha" => base_tree}}} <-
           get_json("repos/#{repo}/git/commits/#{base_sha}") |> step(),
         {:ok, %{"sha" => tree}} <-
           post("repos/#{repo}/git/trees", %{
             base_tree: base_tree,
             tree:
               Enum.map(
                 files,
                 &%{path: &1.path, mode: "100644", type: "blob", content: &1.content}
               )
           })
           |> step(),
         {:ok, %{"sha" => commit}} <-
           post("repos/#{repo}/git/commits", %{message: title, tree: tree, parents: [base_sha]})
           |> step(),
         {:ok, branch} <- create_branch(repo, branch, commit) do
      case post("repos/#{repo}/pulls", %{title: title, head: branch, base: base, body: body}) do
        {:ok, %{"number" => number, "html_url" => url}} ->
          {:ok, %{number: number, url: url, branch: branch}}

        other ->
          # best effort: an orphan branch is only clutter
          CLI.api("DELETE", "repos/#{repo}/git/refs/heads/#{segments(branch)}")

          case step(other) do
            {:ok, _} -> step({:ok, nil})
            error -> error
          end
      end
    end
  end

  # `branch`, else `-2`, `-3`… while GitHub says the ref exists
  defp create_branch(repo, branch, commit, n \\ 1) do
    name = if n == 1, do: branch, else: "#{branch}-#{n}"

    case post("repos/#{repo}/git/refs", %{ref: "refs/heads/" <> name, sha: commit}) do
      {:ok, _} ->
        {:ok, name}

      {:error, {:http, 422, message}} = error ->
        if message =~ ~r/already exists/i and n < 9,
          do: create_branch(repo, branch, commit, n + 1),
          else: step(error)

      error ->
        step(error)
    end
  end

  # a failed write step is :pr_failed with gh's text
  defp step({:ok, %{}} = ok), do: ok
  defp step({:ok, _}), do: {:error, {:pr_failed, "GitHub sent an answer Canopy didn't expect"}}

  defp step(error) do
    {:error, {_kind, raw}} = read_error(error)
    {:error, {:pr_failed, raw}}
  end

  # -- Helpers ------------------------------------------------------------------------

  defp get_json(path, opts \\ []) do
    with {:ok, _status, _headers, body} <- CLI.api("GET", path, opts), do: decode(body)
  end

  defp post(path, input) do
    with {:ok, _status, _headers, body} <- CLI.api("POST", path, input: input), do: decode(body)
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, {:gh, nil, "gh returned something that is not JSON"}}
    end
  end

  # each `/`-separated part of a branch name, escaped for a path
  defp segments(branch) do
    branch
    |> String.split("/")
    |> Enum.map_join("/", fn part -> URI.encode(part, &URI.char_unreserved?/1) end)
  end

  defp read_error({:error, :gh_missing}),
    do:
      {:error,
       {:gh_missing,
        "gh is not installed (no `#{CLI.binary_name()}` found on PATH or in Settings)"}}

  defp read_error({:error, :gh_too_old}),
    do: {:error, {:gh_too_old, "this gh doesn't know `gh api -i`; Canopy needs gh 2.0 or later"}}

  defp read_error({:error, :gh_signed_out}),
    do: {:error, {:gh_signed_out, "gh is not logged in to github.com"}}

  defp read_error({:error, {:http, 401, message}}),
    do: {:error, {:gh_signed_out, "#{message} (HTTP 401)"}}

  defp read_error({:error, {:http, 404, message}}),
    do: {:error, {:not_found, "#{message} (HTTP 404)"}}

  defp read_error({:error, {:http, 403, message}}) do
    if message =~ @permission and not (message =~ ~r/rate limit/i),
      do: {:error, {:read_only, "#{message} (HTTP 403)"}},
      else: {:error, {:gh_failed, "#{message} (HTTP 403)"}}
  end

  defp read_error({:error, {:http, status, message}}),
    do: {:error, {:gh_failed, "#{message} (HTTP #{status})"}}

  defp read_error({:error, {:gh, _code, line}}), do: {:error, {:gh_failed, line}}
  defp read_error({:error, {kind, raw}}) when is_atom(kind), do: {:error, {kind, raw}}
end
