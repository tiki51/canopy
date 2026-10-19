defmodule Canopy.Codex.AllowanceTest do
  @moduledoc "§7.4: what Canopy accepts by itself for a Codex agent in ask-first mode."
  use ExUnit.Case, async: true

  alias Canopy.Codex.Allowance

  describe "plain git commands" do
    test "accepted" do
      for command <- [
            "/bin/zsh -lc 'git status'",
            "/bin/bash -lc 'git status'",
            "sh -c 'git status'",
            ~s(/bin/zsh -lc "git status"),
            "git status",
            "git log --oneline -5",
            "/bin/zsh -lc 'git log --oneline -5'",
            "git commit -m 'a b'",
            ~s(/bin/zsh -lc 'git commit -m '"'"'a b'"'"''),
            "git add -u",
            "git diff --stat",
            "git checkout -- lib/a.ex",
            "  git status  "
          ] do
        assert Allowance.plain_git?(command), "expected #{inspect(command)} to be accepted"
      end
    end

    test "refused" do
      for command <- [
            "git log $(curl x)",
            "/bin/zsh -lc 'git log $(curl x)'",
            "git log `id`",
            "git log $HOME",
            "git status; rm -rf x",
            "/bin/zsh -lc 'git status; rm -rf x'",
            "git status && curl x",
            "git status || true",
            "git status | sh",
            "git log > f",
            "git log < f",
            "git log *",
            "git log ~/x",
            "git -c core.pager=sh log",
            "git config user.name x",
            "git -C /tmp status",
            "git --git-dir=/tmp/x status",
            "git fetch --upload-pack=./x.sh .",
            "git rebase -x ./x.sh main",
            "git grep -O./x.sh foo",
            "git grep -nO./x.sh foo",
            "git grep -O ./x.sh foo",
            "git grep --open-files-in-pager=./x.sh foo",
            "git grep --open=./x.sh foo",
            "git difftool --extcmd=./x.sh",
            "git diff --ext-diff",
            "git diff --textconv",
            "git diff --output=/tmp/x",
            "git diff --output /tmp/x",
            "git diff --outp=/tmp/x",
            "git push",
            "git push origin main",
            "git status\nrm -rf x",
            "/bin/zsh -lc 'git status\nrm -rf x'",
            "/bin/zsh -lc 'git status\r rm -rf x'",
            "/bin/dash -c 'git status'",
            "/bin/zsh -lc 'git status' extra",
            "/bin/zsh -lc 'git status",
            "gitx status",
            "git",
            "",
            "ls"
          ] do
        refute Allowance.plain_git?(command), "expected #{inspect(command)} to be refused"
      end
    end

    test "non-binary commands are refused" do
      refute Allowance.plain_git?(nil)
      assert Allowance.simple_words(nil) == :error
      assert Allowance.unwrap(nil) == nil
    end

    test "simple_words/1 unwraps and lexes, or refuses any metacharacter, quoted or not" do
      assert Allowance.simple_words("/bin/zsh -lc 'npm install csv-stringify'") ==
               {:ok, ["npm", "install", "csv-stringify"]}

      assert Allowance.simple_words("echo 'a;b'") == :error
      assert Allowance.simple_words("echo \"$(id)\"") == :error
      assert Allowance.simple_words("   ") == :error
    end

    test "unwrap/1 undoes the shell wrapper and nothing else" do
      assert Allowance.unwrap("/bin/zsh -lc 'git status'") == "git status"
      assert Allowance.unwrap("bash -c 'a b'") == "a b"
      assert Allowance.unwrap("/bin/dash -c 'git status'") == "/bin/dash -c 'git status'"
      assert Allowance.unwrap("git status") == "git status"
    end
  end

  describe "lex/1" do
    test "words, quotes and escapes, no expansion" do
      assert Allowance.lex("a  b\tc") == {:ok, ["a", "b", "c"]}
      assert Allowance.lex(~s(a 'b c' "d e" f\\ g)) == {:ok, ["a", "b c", "d e", "f g"]}
      assert Allowance.lex(~s(a'b'"c")) == {:ok, ["abc"]}
      assert Allowance.lex(~s("a\\"b")) == {:ok, [~s(a"b)]}
      assert Allowance.lex(~s('a\\b')) == {:ok, ["a\\b"]}
      assert Allowance.lex(~s("a\\x")) == {:ok, ["a\\x"]}
      assert Allowance.lex(~s("$HOME")) == {:ok, ["$HOME"]}
      assert Allowance.lex("''") == {:ok, [""]}
      assert Allowance.lex("") == {:ok, []}
      assert Allowance.lex("   ") == {:ok, []}
    end

    test "an open quote is an error" do
      assert Allowance.lex("'abc") == {:error, :unterminated}
      assert Allowance.lex(~s("abc)) == {:error, :unterminated}
    end
  end

  describe "paths" do
    setup %{tmp_dir: dir} do
      repo = Path.join(dir, "repo")
      outside = Path.join(dir, "outside")
      File.mkdir_p!(Path.join(repo, "lib"))
      File.mkdir_p!(outside)
      File.write!(Path.join(repo, "lib/a.ex"), "")
      {:ok, repo: repo, outside: outside}
    end

    @describetag :tmp_dir

    test "an in-repo file is accepted, existing or not", %{repo: repo} do
      assert Allowance.in_repo_files?([Path.join(repo, "lib/a.ex")], repo)
      assert Allowance.in_repo_files?([Path.join(repo, "lib/new/b.ex")], repo)
      assert Allowance.in_repo_files?(["lib/a.ex"], repo)
      assert Allowance.in_repo_files?([Path.join(repo, "lib/.mcp.json")], repo)
    end

    test "no paths is not an allowance", %{repo: repo} do
      refute Allowance.in_repo_files?([], repo)
    end

    test "one path outside refuses the whole change", %{repo: repo, outside: outside} do
      refute Allowance.in_repo_files?(
               [Path.join(repo, "lib/a.ex"), Path.join(outside, "x")],
               repo
             )
    end

    test "refused: parent dirs, symlinks out, protected paths", %{repo: repo, outside: outside} do
      File.ln_s!(outside, Path.join(repo, "out"))
      File.write!(Path.join(outside, "f"), "")
      File.ln_s!(Path.join(outside, "f"), Path.join(repo, "f-link"))

      for path <- [
            Path.join(repo, "../x"),
            "../x",
            Path.join(repo, "lib/../../x"),
            Path.join(repo, "f-link"),
            Path.join(repo, "out"),
            # not yet existing, under a symlinked dir that points outside
            Path.join(repo, "out/new.txt"),
            Path.join(repo, ".git/hooks/pre-commit"),
            Path.join(repo, ".codex/config.toml"),
            Path.join(repo, ".claude/settings.json"),
            Path.join(repo, ".mcp.json"),
            Path.join(repo, ".canopy/x"),
            Path.join(repo, ".GIT/x"),
            Path.join(repo, ".Codex/config.toml"),
            Path.join(repo, ".MCP.json"),
            Path.join(outside, "x"),
            "/etc/hosts"
          ] do
        refute Allowance.in_repo_files?([path], repo), "expected #{path} to be refused"
      end
    end

    test "agent and git settings are protected at any depth", %{repo: repo} do
      for rel <- [
            "sub/.git",
            "vendor/lib/.git/config",
            "apps/web/.codex/config.toml",
            "apps/web/.Claude/settings.json",
            "deep/a/b/.canopy/notes.md"
          ] do
        assert Allowance.protected?(Path.join(repo, rel), repo), rel
        refute Allowance.in_repo_files?([Path.join(repo, rel)], repo), rel
      end

      # only the repository's own .mcp.json; a nested one, or a name that
      # merely contains a protected one, is an ordinary file
      for rel <- ["apps/web/.mcp.json", "lib/git.ex", "docs/.github/x.yml", "a/.gitignore"] do
        refute Allowance.protected?(Path.join(repo, rel), repo), rel
      end
    end

    test "inside?/2 vs protected?/2", %{repo: repo, outside: outside} do
      assert Allowance.inside?(Path.join(repo, ".git/config"), repo)
      assert Allowance.protected?(Path.join(repo, ".git/config"), repo)
      refute Allowance.protected?(Path.join(repo, "lib/a.ex"), repo)
      refute Allowance.inside?(Path.join(outside, "x"), repo)
      refute Allowance.protected?(Path.join(outside, ".git"), repo)
      refute Allowance.inside?(nil, repo)
      refute Allowance.inside?("/x", nil)
    end

    test "a repository reached through a symlink still contains its files", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "real/lib"))
      File.ln_s!(Path.join(dir, "real"), Path.join(dir, "linked"))
      linked = Path.join(dir, "linked")

      assert Allowance.in_repo_files?([Path.join(dir, "real/lib/a.ex")], linked)
      assert Allowance.in_repo_files?([Path.join(linked, "lib/a.ex")], Path.join(dir, "real"))
    end

    test "display_path/2", %{repo: repo, outside: outside} do
      assert Allowance.display_path(Path.join(repo, "lib/a.ex"), repo) == "lib/a.ex"
      assert Allowance.display_path(repo, repo) == "."

      home = System.user_home!()
      assert Allowance.display_path(Path.join(home, ".npmrc"), repo) == "~/.npmrc"
      assert Allowance.display_path(home, repo) == "~"
      assert Allowance.display_path("/etc/hosts", repo) == "/etc/hosts"
      assert Allowance.display_path(nil, repo) == nil

      # outside the repository, the path is absolute (under home here, so `~`)
      shown = Allowance.display_path(Path.join(outside, "x"), repo)
      assert String.ends_with?(shown, "/outside/x")
      assert String.starts_with?(shown, "/") or String.starts_with?(shown, "~/")
    end
  end
end
