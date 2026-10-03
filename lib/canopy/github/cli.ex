defmodule Canopy.GitHub.CLI do
  @moduledoc """
  `Canopy.GitHub` through the user's `gh` CLI. Every call is a fixed argv
  run with `System.cmd/3` (no shell, so nothing an agent wrote is ever
  interpreted), under a 30 second timeout.

  Checks use `gh api -i -H "If-None-Match: <etag>" <path>`, which works on old
  gh (2.x; the installed one may be 2.5.2, whose `gh run list` has no
  `--status`). `-i` prints the HTTP status line and headers before the body;
  that line, not the exit code, says what happened, because gh exits 1 on a
  304 Not Modified. A missing, unauthenticated, or too old gh comes back as
  an error that says so and how to fix it.

  The binary comes from Settings (`gh_binary`, a name on `PATH` or a path);
  `config :canopy, :github, binary: ...` overrides it (tests point it at
  `test/support/fake_gh.sh`).
  """

  @behaviour Canopy.GitHub

  alias Canopy.GitHub

  @timeout_ms 30_000
  @min_version {2, 0, 0}
  # quiet, non-interactive, and never paged
  @env [
    {"GH_NO_UPDATE_NOTIFIER", "1"},
    {"GH_PROMPT_DISABLED", "1"},
    {"GH_PAGER", "cat"},
    {"NO_COLOR", "1"},
    {"CLICOLOR", "0"}
  ]

  @doc "The configured binary: the config override, else Settings, else `gh`."
  def binary_name do
    case Application.get_env(:canopy, :github, [])[:binary] do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        case Canopy.Settings.get().gh_binary do
          name when is_binary(name) and name != "" -> name
          _ -> "gh"
        end
    end
  end

  @impl true
  def probe(check, etag) do
    header = if is_binary(etag) and etag != "", do: ["-H", "If-None-Match: " <> etag], else: []

    with {:ok, output, code} <- run(["api", "-i"] ++ header ++ [GitHub.path(check)]) do
      case response(output) do
        {:ok, 304, _headers, _body} ->
          {:ok, :not_modified}

        {:ok, 200, headers, body} ->
          with {:ok, json} <- decode(body) do
            {:ok,
             %{
               etag: headers["etag"],
               items: GitHub.items(check, json),
               next?: next_page?(headers),
               poll_interval: integer(headers["x-poll-interval"])
             }}
          end

        {:ok, status, _headers, body} ->
          {:error, http_error(status, body)}

        :none ->
          {:error, failure(output, code)}
      end
    end
  end

  @impl true
  def page(check, n) when is_integer(n) and n > 1 do
    with {:ok, output, code} <- run(["api", "-i", GitHub.path(check, n)]) do
      case response(output) do
        {:ok, 200, headers, body} ->
          with {:ok, json} <- decode(body) do
            {:ok, %{items: GitHub.items(check, json), next?: next_page?(headers)}}
          end

        {:ok, status, _headers, body} ->
          {:error, http_error(status, body)}

        :none ->
          {:error, failure(output, code)}
      end
    end
  end

  @impl true
  def default_branch(repo) do
    with {:ok, output, code} <- run(["api", "-i", "repos/#{repo}"]) do
      case response(output) do
        {:ok, 200, _headers, body} ->
          case decode(body) do
            {:ok, %{"default_branch" => branch}} when is_binary(branch) -> {:ok, branch}
            {:ok, _} -> {:error, "GitHub did not say which branch #{repo} defaults to"}
            error -> error
          end

        {:ok, status, _headers, body} ->
          {:error, http_error(status, body)}

        :none ->
          {:error, failure(output, code)}
      end
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, "gh returned something that is not JSON"}
    end
  end

  defp next_page?(headers), do: (headers["link"] || "") =~ ~s(rel="next")

  @impl true
  def resolve_repo(repo_path) do
    case run(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], cd: repo_path) do
      {:ok, output, 0} ->
        repo = output |> String.split("\n", trim: true) |> List.last("") |> String.trim()

        if GitHub.valid_repo?(repo),
          do: {:ok, repo},
          else:
            {:error, "gh could not tell which GitHub repository this is; pass repo as owner/name"}

      {:ok, output, code} ->
        {:error, failure(output, code)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def status do
    with {:ok, version_out, 0} <- run(["--version"]),
         {:ok, version} <- version(version_out) do
      {auth_out, logged_in?} =
        case run(["auth", "status"]) do
          {:ok, out, 0} -> {out, true}
          {:ok, out, _} -> {out, false}
          {:error, reason} -> {reason, false}
        end

      {:ok,
       %{
         binary: binary_name(),
         version: version,
         too_old?: too_old?(version),
         logged_in?: logged_in?,
         account: account(auth_out),
         detail: auth_out |> String.split("\n", trim: true) |> Enum.map_join(" ", &String.trim/1)
       }}
    else
      {:ok, out, code} -> {:error, failure(out, code)}
      {:error, _} = error -> error
    end
  end

  # -- Running gh ---------------------------------------------------------------

  defp run(args, opts \\ []) do
    case executable(binary_name()) do
      nil ->
        {:error,
         "gh is not installed (no `#{binary_name()}` found); install the GitHub CLI and run `gh auth login`, or set its path in Settings"}

      path ->
        cmd_opts =
          [stderr_to_stdout: true, env: @env] ++
            if(opts[:cd], do: [cd: opts[:cd]], else: [])

        # the launch can raise (a path that is not executable): caught inside
        # the task, so it is a reason, never a crash of whoever asked
        task =
          Task.async(fn ->
            try do
              {:ok, System.cmd(path, args, cmd_opts)}
            rescue
              e -> {:error, "gh failed to run (#{path}): #{Exception.message(e)}"}
            catch
              kind, reason -> {:error, "gh failed to run (#{path}): #{inspect({kind, reason})}"}
            end
          end)

        case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, {output, code}}} -> {:ok, output, code}
          {:ok, {:error, reason}} -> {:error, reason}
          {:exit, reason} -> {:error, "gh failed to run: #{inspect(reason)}"}
          nil -> {:error, "gh did not answer within #{div(@timeout_ms, 1000)} seconds"}
        end
    end
  end

  defp executable(name) do
    cond do
      String.contains?(name, "/") -> if File.regular?(name), do: name
      true -> System.find_executable(name)
    end
  end

  # -- Reading gh's output ---------------------------------------------------------

  # `gh api -i`: the status line, header lines, a blank line, the body. gh's
  # own complaints (`gh: HTTP 304`) arrive on stderr, merged in after the body.
  @doc false
  def response(output) do
    output = String.replace(output, "\r\n", "\n")

    case Regex.run(~r/^HTTP\/[\d.]+ (\d{3})[^\n]*\n/m, output, return: :index) do
      [{start, len}, {code_at, code_len}] ->
        status = output |> binary_part(code_at, code_len) |> String.to_integer()
        rest = binary_part(output, start + len, byte_size(output) - start - len)

        {header_text, body} =
          case String.split(rest, "\n\n", parts: 2) do
            [h, b] -> {h, b}
            [h] -> {h, ""}
          end

        headers =
          header_text
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, ":", parts: 2) do
              [k, v] -> [{String.downcase(String.trim(k)), String.trim(v)}]
              _ -> []
            end
          end)
          |> Map.new()

        body =
          body
          |> String.split("\n")
          |> Enum.reject(&String.starts_with?(&1, "gh: "))
          |> Enum.join("\n")
          |> String.trim()

        {:ok, status, headers, body}

      nil ->
        :none
    end
  end

  defp http_error(status, body) do
    message =
      case Jason.decode(body) do
        {:ok, %{"message" => m}} when is_binary(m) -> m
        _ -> nil
      end

    case status do
      401 ->
        "GitHub said 401: gh's login is no longer valid; run `gh auth login` in a terminal"

      404 ->
        "GitHub said 404: no such repository, branch, or workflow (or gh's login cannot see it)"

      403 ->
        "GitHub said 403: #{message || "forbidden (or rate limited)"}"

      429 ->
        "GitHub said 429: rate limited; the watch tries again later"

      _ ->
        "GitHub said #{status}" <> if(message, do: ": " <> message, else: "")
    end
  end

  # gh failed before talking to GitHub: say why in words a person can act on.
  defp failure(output, code) do
    text = String.downcase(output)

    cond do
      text =~ "auth login" or text =~ "not logged" or text =~ "authentication required" ->
        "gh is not logged in: run `gh auth login` in a terminal"

      text =~ "unknown flag" or text =~ "unknown command" or text =~ "unknown shorthand" ->
        "gh is too old for watches; update the GitHub CLI (watches need `gh api -i`, gh 2.0 or later)"

      text =~ "no git remotes" or text =~ "none of the git remotes" or
          text =~ "not a git repository" ->
        "gh found no GitHub remote in this repository; pass repo as owner/name"

      true ->
        first = output |> String.split("\n", trim: true) |> List.first("no output")
        "gh failed (exit #{code}): #{String.slice(first, 0, 200)}"
    end
  end

  defp version(output) do
    case Regex.run(~r/gh version (\d+)\.(\d+)\.(\d+)/, output) do
      [_, a, b, c] -> {:ok, "#{a}.#{b}.#{c}"}
      nil -> {:error, "`#{binary_name()} --version` does not look like the GitHub CLI"}
    end
  end

  defp too_old?(version) do
    [a, b, c] = version |> String.split(".") |> Enum.map(&String.to_integer/1)
    {a, b, c} < @min_version
  end

  defp account(output) do
    case Regex.run(~r/(?:Logged in to \S+ (?:as|account) )(\S+)/, output) do
      [_, login] -> String.trim_trailing(login, ")")
      nil -> nil
    end
  end

  defp integer(nil), do: nil

  defp integer(text) do
    case Integer.parse(text) do
      {n, _} -> n
      :error -> nil
    end
  end
end
