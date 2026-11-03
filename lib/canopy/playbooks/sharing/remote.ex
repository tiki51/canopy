defmodule Canopy.Playbooks.Sharing.Remote do
  @moduledoc """
  The GitHub repository shared playbooks live in, as `Canopy.Playbooks.Sharing`
  needs it. `Canopy.Playbooks.Sharing.Remote.GH` reaches it through the user's
  `gh`; tests configure an in-memory one
  (`config :canopy, :playbook_sharing, remote: ...`).

  Errors are `{kind, raw}`: `kind` one of `Canopy.Playbooks.Sharing`'s error
  kinds, `raw` gh's or GitHub's own text.
  """

  @type error :: {atom(), String.t()}
  @type file :: %{path: String.t(), sha: String.t(), size: non_neg_integer()}

  @callback account() :: {:ok, String.t()} | {:error, error()}
  @callback repo(repo :: String.t()) ::
              {:ok, %{default_branch: String.t(), can_push?: boolean()}} | {:error, error()}
  @callback list(
              repo :: String.t(),
              branch :: String.t(),
              folder :: String.t(),
              etag :: String.t() | nil
            ) ::
              {:ok, :not_modified}
              | {:ok, :no_folder}
              | {:ok, %{etag: String.t() | nil, files: [file()]}}
              | {:error, error()}
  @callback read(repo :: String.t(), sha :: String.t()) :: {:ok, String.t()} | {:error, error()}
  @callback last_commit(repo :: String.t(), branch :: String.t(), path :: String.t()) ::
              {:ok, %{by: String.t() | nil, at: DateTime.t() | nil}} | {:error, error()}
  @callback open_pr(
              repo :: String.t(),
              base :: String.t(),
              branch :: String.t(),
              files :: [%{path: String.t(), content: String.t()}],
              title :: String.t(),
              body :: String.t()
            ) ::
              {:ok, %{number: pos_integer(), url: String.t(), branch: String.t()}}
              | {:error, error()}
  @callback pr(repo :: String.t(), number :: pos_integer()) ::
              {:ok, :open | :merged | :closed} | {:error, error()}

  @doc "The configured implementation."
  def impl do
    Application.get_env(:canopy, :playbook_sharing, [])[:remote] ||
      Canopy.Playbooks.Sharing.Remote.GH
  end

  @file_name ~r/\A[A-Za-z0-9_.-]+\.md\z/
  @sha ~r/\A[0-9a-f]{40}\z/

  @doc "Whether a file's name (the last path segment) is one Canopy reads and puts in a request."
  def file_name_ok?(path) when is_binary(path), do: Regex.match?(@file_name, Path.basename(path))
  def file_name_ok?(_), do: false

  @doc "Whether `sha` is a git blob sha (40 lowercase hex characters)."
  def sha_ok?(sha) when is_binary(sha), do: Regex.match?(@sha, sha)
  def sha_ok?(_), do: false
end
