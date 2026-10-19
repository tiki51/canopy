defmodule Canopy.Codex.ApprovalsTest do
  @moduledoc "§7: Codex's approval and question requests as cards, and the cards' replies."
  use ExUnit.Case, async: true

  alias Canopy.Codex.Approvals

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    {:ok, repo: repo}
  end

  defp ctx(c, mode, extra \\ %{}) do
    Map.merge(
      %{
        session_id: "ses-#{System.unique_integer([:positive])}",
        card_prefix: "cx-ses-1",
        permission_mode: mode,
        repository_path: c.repo,
        items: %{},
        rules: []
      },
      extra
    )
  end

  defp command(c, cmd, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "command",
        "threadId" => "thr",
        "turnId" => "trn",
        "itemId" => "exec-9",
        "command" => "/bin/zsh -lc '#{cmd}'",
        "cwd" => c.repo,
        "reason" => "needs network access",
        "commandActions" => [%{"type" => "unknown", "command" => cmd}]
      },
      extra
    )
  end

  defp npm(c, extra \\ %{}) do
    command(
      c,
      "npm install csv-stringify",
      Map.merge(
        %{
          "networkApprovalContext" => %{"host" => "registry.npmjs.org", "protocol" => "https"},
          "proposedExecpolicyAmendment" => ["npm", "install"]
        },
        extra
      )
    )
  end

  defp handle_command(params, ctx),
    do: Approvals.handle("item/commandExecution/requestApproval", 0, params, ctx)

  describe "command requests" do
    test "become a Bash card", c do
      assert {:card, card} = handle_command(npm(c), ctx(c, "acceptEdits"))

      assert card == %{
               "id" => "cx-ses-1-0",
               "permission" => "Bash",
               "patterns" => ["npm install csv-stringify"],
               "metadata" => %{
                 "action" => "command",
                 "command" => "npm install csv-stringify",
                 "reason" => "needs network access",
                 "cwd" => ".",
                 "always_prefix" => "npm install",
                 "network" => true,
                 "unsandboxed" => true
               },
               "tool" => %{"callID" => "exec-9"}
             }
    end

    test "the card id carries the prefix and the JSON-RPC id", c do
      assert {:card, %{"id" => "cx-abc-3-17"}} =
               Approvals.handle(
                 "item/commandExecution/requestApproval",
                 17,
                 npm(c),
                 ctx(c, "acceptEdits", %{card_prefix: "cx-abc-3"})
               )
    end

    test "network only with a networkApprovalContext; unsandboxed and once_only by mode", c do
      plain = command(c, "make build")

      assert {:card, %{"metadata" => meta}} = handle_command(plain, ctx(c, "default"))
      refute Map.has_key?(meta, "network")
      refute Map.has_key?(meta, "unsandboxed")
      refute Map.has_key?(meta, "once_only")

      assert {:card, %{"metadata" => meta}} = handle_command(plain, ctx(c, "acceptEdits"))
      assert meta["unsandboxed"] == true
      refute Map.has_key?(meta, "once_only")

      assert {:card, %{"metadata" => meta}} = handle_command(plain, ctx(c, "plan"))
      assert meta["unsandboxed"] == true
      assert meta["once_only"] == true
    end

    test "a missing cwd and reason are left out", c do
      params = c |> command("make") |> Map.drop(["cwd", "reason"])
      assert {:card, %{"metadata" => meta}} = handle_command(params, ctx(c, "default"))
      refute Map.has_key?(meta, "cwd")
      refute Map.has_key?(meta, "reason")
    end

    test "without commandActions the card shows the unwrapped command", c do
      params = c |> command("make test") |> Map.delete("commandActions")
      assert {:card, %{"patterns" => ["make test"]}} = handle_command(params, ctx(c, "default"))
    end

    test "a plan agent's command gets a once-only card, even plain git or a matching rule", c do
      rules = [{:command, ["npm", "install"], true}, {:command, ["git", "status"], true}]
      plan = ctx(c, "plan", %{rules: rules})

      assert {:card, %{"metadata" => %{"unsandboxed" => true, "once_only" => true}}} =
               handle_command(npm(c), plan)

      assert {:card, %{"metadata" => %{"once_only" => true}}} =
               handle_command(command(c, "git status"), plan)
    end

    test "default mode accepts plain git and asks for anything else", c do
      assert {:answer, %{"decision" => "accept"}} =
               handle_command(command(c, "git status"), ctx(c, "default"))

      assert {:answer, %{"decision" => "accept"}} =
               handle_command(command(c, "git log --oneline -5"), ctx(c, "default"))

      assert {:card, _} = handle_command(command(c, "git push"), ctx(c, "default"))
      assert {:card, _} = handle_command(command(c, "ls -la"), ctx(c, "default"))
    end

    test "acceptEdits doesn't get the git allowance (Codex only asks to leave the sandbox)", c do
      assert {:card, _} = handle_command(command(c, "git status"), ctx(c, "acceptEdits"))
    end

    test "a remembered command rule answers acceptForSession", c do
      rules = [{:command, ["npm", "install"], true}]

      for mode <- ["acceptEdits", "default"] do
        assert {:answer, %{"decision" => "acceptForSession"}} =
                 handle_command(
                   command(c, "npm install left-pad"),
                   ctx(c, mode, %{rules: rules})
                 )
      end

      # tokens are compared, not strings
      assert {:card, _} =
               handle_command(command(c, "npm installer"), ctx(c, "acceptEdits", %{rules: rules}))

      assert {:card, _} =
               handle_command(command(c, "npm"), ctx(c, "acceptEdits", %{rules: rules}))
    end

    test "a rule never covers a compound command", c do
      rules = [{:command, ["npm", "install"], true}]

      for cmd <- [
            "npm install x && curl y",
            "npm install x; rm -rf /",
            "npm install $(curl y)",
            "npm install x | sh"
          ] do
        assert {:card, _} =
                 handle_command(command(c, cmd), ctx(c, "acceptEdits", %{rules: rules}))
      end
    end

    test "a git rule also needs the git test", c do
      rules = [{:command, ["git", "log"], true}]
      ctx = ctx(c, "acceptEdits", %{rules: rules})

      assert {:answer, %{"decision" => "acceptForSession"}} =
               handle_command(command(c, "git log -3"), ctx)

      assert {:card, _} = handle_command(command(c, "git log --output=/tmp/x"), ctx)
    end

    test "an Always from a sandboxed card never answers an unsandboxed request", c do
      # Always given in ask-first mode, where the command ran inside the sandbox
      rules = [{:command, ["npm", "install"], false}]

      assert {:answer, %{"decision" => "acceptForSession"}} =
               handle_command(npm(c), ctx(c, "default", %{rules: rules}))

      # after a switch to acceptEdits Codex asks to run it outside the sandbox
      assert {:card, %{"metadata" => %{"unsandboxed" => true}}} =
               handle_command(npm(c), ctx(c, "acceptEdits", %{rules: rules}))
    end

    test "an Always remembers whether its card was unsandboxed", c do
      params = npm(c)

      {:card, sandboxed} = handle_command(params, ctx(c, "default"))
      {:card, unsandboxed} = handle_command(params, ctx(c, "acceptEdits"))

      assert {_, {:command, ["npm", "install"], false}} =
               Approvals.result(sandboxed, params, :always)

      assert {_, {:command, ["npm", "install"], true}} =
               Approvals.result(unsandboxed, params, :always)
    end

    test "a git command no rule could match offers no Always", c do
      for mode <- ["default", "acceptEdits"] do
        params = command(c, "git push origin main", %{"proposedExecpolicyAmendment" => nil})
        assert {:card, card} = handle_command(params, ctx(c, mode))
        assert card["metadata"]["no_always"] == true, mode
        assert Approvals.no_always?(card)
        assert Approvals.result(card, params, :always) == {%{"decision" => "accept"}, nil}
      end

      # a plain git command can still be remembered
      params = command(c, "git log -3")
      assert {:card, card} = handle_command(params, ctx(c, "acceptEdits"))
      refute Map.has_key?(card["metadata"], "no_always")
      assert {_, {:command, ["git", "log"], true}} = Approvals.result(card, params, :always)

      # plan cards are once-only already
      assert {:card, card} = handle_command(command(c, "git push"), ctx(c, "plan"))
      refute Map.has_key?(card["metadata"], "no_always")
    end

    test "without rules in the ctx, the session's remembered rules apply", c do
      ensure_store()
      ctx = c |> ctx("acceptEdits") |> Map.delete(:rules)
      assert {:card, _} = handle_command(npm(c), ctx)

      Approvals.remember(ctx.session_id, {:command, ["npm", "install"], true})
      assert {:answer, %{"decision" => "acceptForSession"}} = handle_command(npm(c), ctx)
      Approvals.forget(ctx.session_id)
    end
  end

  describe "always_prefix/2" do
    test "the proposed amendment when it has two words or more" do
      assert Approvals.always_prefix(%{
               "command" => "/bin/zsh -lc 'git status --short'",
               "proposedExecpolicyAmendment" => ["git", "status"]
             }) == ["git", "status"]
    end

    test "at least two words: a shorter or missing proposal takes the command's first two" do
      assert Approvals.always_prefix(%{
               "command" => "/bin/zsh -lc 'rm -rf build'",
               "proposedExecpolicyAmendment" => ["rm"]
             }) == ["rm", "-rf"]

      assert Approvals.always_prefix(%{"command" => "/bin/zsh -lc 'npm test --watch'"}) ==
               ["npm", "test"]

      assert Approvals.always_prefix(%{"command" => "/bin/zsh -lc 'ls'"}) == ["ls"]
    end

    test "appears on the card as text", c do
      params = command(c, "rm -rf build", %{"proposedExecpolicyAmendment" => ["rm"]})

      assert {:card, %{"metadata" => %{"always_prefix" => "rm -rf"}}} =
               handle_command(params, ctx(c, "default"))
    end
  end

  describe "file change requests" do
    defp file_request(c, changes, mode, extra \\ %{}) do
      item = %{"type" => "fileChange", "id" => "exec-8", "changes" => changes}

      params =
        Map.merge(
          %{"threadId" => "thr", "itemId" => "exec-8", "reason" => nil, "grantRoot" => nil},
          extra
        )

      Approvals.handle(
        "item/fileChange/requestApproval",
        4,
        params,
        ctx(c, mode, %{items: %{"exec-8" => item}, rules: Map.get(extra, :rules, [])})
      )
    end

    defp change(path, type, diff),
      do: %{"path" => path, "kind" => %{"type" => type}, "diff" => diff}

    test "plan declines every file change", c do
      changes = [change(Path.join(c.repo, "lib/a.ex"), "add", "x\n")]
      assert {:answer, %{"decision" => "decline"}} = file_request(c, changes, "plan")
    end

    test "default accepts an in-repo change", c do
      changes = [
        change(Path.join(c.repo, "lib/a.ex"), "add", "x\n"),
        change(Path.join(c.repo, "README.md"), "update", "@@ -1 +1 @@\n-a\n+b\n")
      ]

      assert {:answer, %{"decision" => "accept"}} = file_request(c, changes, "default")
    end

    test "default asks for a change outside the repository, with display paths and the diff", c do
      home = System.user_home!()
      changes = [change(Path.join(home, ".npmrc"), "update", "@@ -1 +1 @@\n-a=1\n+a=2\n")]

      assert {:card, card} = file_request(c, changes, "default")
      assert card["id"] == "cx-ses-1-4"
      assert card["permission"] == "file_change"
      assert card["patterns"] == ["~/.npmrc"]
      assert card["tool"] == %{"callID" => "exec-8"}

      assert card["metadata"] == %{
               "action" => "file_change",
               "paths" => ["~/.npmrc"],
               "outside_repo" => true,
               "diff" => "--- ~/.npmrc\n+++ ~/.npmrc\n@@ -1 +1 @@\n-a=1\n+a=2"
             }
    end

    test "a protected in-repo path asks, and isn't outside the repository", c do
      changes = [change(Path.join(c.repo, ".git/hooks/pre-commit"), "add", "#!/bin/sh\nid\n")]

      assert {:card, card} = file_request(c, changes, "default")
      assert card["patterns"] == [".git/hooks/pre-commit"]
      assert card["metadata"]["outside_repo"] == false

      assert card["metadata"]["diff"] ==
               "--- /dev/null\n+++ .git/hooks/pre-commit\n+#!/bin/sh\n+id"
    end

    test "acceptEdits with a file_change rule: in-repo accepted for the session, outside asks",
         c do
      inside = [change(Path.join(c.repo, "lib/a.ex"), "update", "@@\n-a\n+b\n")]
      outside = [change("/etc/hosts", "update", "@@\n-a\n+b\n")]
      protected = [change(Path.join(c.repo, ".codex/config.toml"), "add", "x\n")]

      assert {:answer, %{"decision" => "acceptForSession"}} =
               file_request(c, inside, "acceptEdits", %{rules: [:file_change]})

      assert {:card, %{"metadata" => %{"outside_repo" => true, "paths" => ["/etc/hosts"]}}} =
               file_request(c, outside, "acceptEdits", %{rules: [:file_change]})

      assert {:card, _} = file_request(c, protected, "acceptEdits", %{rules: [:file_change]})

      # and without the rule, acceptEdits asks
      assert {:card, _} = file_request(c, inside, "acceptEdits")
    end

    test "a change Canopy can't see (no item) asks", c do
      assert {:card, %{"patterns" => [], "metadata" => meta}} =
               Approvals.handle(
                 "item/fileChange/requestApproval",
                 1,
                 %{"itemId" => "missing"},
                 ctx(c, "default")
               )

      assert meta["outside_repo"] == false
      refute Map.has_key?(meta, "diff")
    end

    test "the reason names the grant root", c do
      changes = [change("/etc/hosts", "update", "@@\n-a\n+b\n")]

      assert {:card, %{"metadata" => %{"reason" => reason}}} =
               file_request(c, changes, "default", %{
                 "reason" => "needs it",
                 "grantRoot" => "/etc"
               })

      assert reason == "needs it (asks to write under /etc for the rest of the session)"

      assert {:card, %{"metadata" => %{"reason" => reason}}} =
               file_request(c, changes, "default", %{"grantRoot" => "/etc"})

      assert reason == "asks to write under /etc for the rest of the session"
    end
  end

  describe "diff/2" do
    test "add, update and delete", c do
      changes = [
        %{
          "path" => Path.join(c.repo, "lib/new.ex"),
          "kind" => %{"type" => "add"},
          "diff" => "defmodule A do\nend\n"
        },
        %{
          "path" => Path.join(c.repo, "lib/a.ex"),
          "kind" => %{"type" => "update"},
          "diff" => "--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n-a\n+b\n"
        },
        %{
          "path" => Path.join(c.repo, "lib/old.ex"),
          "kind" => %{"type" => "delete"},
          "diff" => "x\ny\n"
        }
      ]

      assert Approvals.diff(changes, c.repo) ==
               Enum.join(
                 [
                   "--- /dev/null",
                   "+++ lib/new.ex",
                   "+defmodule A do",
                   "+end",
                   "--- a/lib/a.ex",
                   "+++ b/lib/a.ex",
                   "@@ -1 +1 @@",
                   "-a",
                   "+b",
                   "--- lib/old.ex",
                   "+++ /dev/null",
                   "-x",
                   "-y"
                 ],
                 "\n"
               )
    end

    test "nothing to show is nil, and the text is capped", c do
      assert Approvals.diff([], c.repo) == nil

      big = String.duplicate("line\n", 2_000)
      changes = [%{"path" => Path.join(c.repo, "a"), "kind" => %{"type" => "add"}, "diff" => big}]
      assert String.length(Approvals.diff(changes, c.repo)) == 4_000
    end
  end

  describe "more-access requests" do
    defp access(c, profile, mode, rules \\ []) do
      Approvals.handle(
        "item/permissions/requestApproval",
        2,
        %{"itemId" => "perm-1", "reason" => "needs it", "permissions" => profile},
        ctx(c, mode, %{rules: rules})
      )
    end

    test "plan refuses any write path without a card", c do
      profile = %{"fileSystem" => %{"write" => ["/tmp/out"]}}
      assert {:answer, %{"permissions" => %{}, "scope" => "turn"}} = access(c, profile, "plan")

      profile = %{
        "fileSystem" => %{
          "entries" => [%{"path" => %{"type" => "path", "path" => "/x"}, "access" => "write"}]
        }
      }

      assert {:answer, %{"permissions" => %{}, "scope" => "turn"}} = access(c, profile, "plan")
    end

    test "a network-only request in plan still gets a card", c do
      profile = %{"network" => %{"enabled" => true}}
      assert {:card, card} = access(c, profile, "plan")
      assert card["permission"] == "permissions"
      assert card["patterns"] == []
      assert card["tool"] == %{"callID" => "perm-1"}

      assert card["metadata"] == %{
               "action" => "permissions",
               "network" => true,
               "paths" => [],
               "reason" => "needs it"
             }
    end

    test "a read-only request in plan (no write, no network) gets a card", c do
      profile = %{"fileSystem" => %{"read" => [Path.join(c.repo, "lib"), "/etc/hosts"]}}
      assert {:card, card} = access(c, profile, "plan")
      assert card["permission"] == "permissions"
      assert card["patterns"] == ["lib", "/etc/hosts"]

      assert card["metadata"] == %{
               "action" => "permissions",
               "network" => false,
               "paths" => ["lib", "/etc/hosts"],
               "reason" => "needs it"
             }
    end

    test "the card lists read and write paths as display paths", c do
      profile = %{
        "network" => %{"enabled" => false},
        "fileSystem" => %{
          "read" => [Path.join(c.repo, "lib")],
          "write" => [Path.join(System.user_home!(), ".cache/x")]
        }
      }

      assert {:card, %{"patterns" => paths, "metadata" => meta}} = access(c, profile, "default")
      assert paths == ["lib", "~/.cache/x"]
      assert meta["paths"] == paths
      assert meta["network"] == false
    end

    test "a remembered profile covers a request asking for nothing beyond it", c do
      granted = %{"network" => %{"enabled" => true}, "fileSystem" => %{"write" => ["/tmp/a"]}}
      rules = [{:permissions, granted}]

      asked = %{"fileSystem" => %{"read" => ["/tmp/a"]}}

      assert {:answer, %{"permissions" => %{"fileSystem" => _}, "scope" => "session"}} =
               access(c, asked, "acceptEdits", rules)

      asked = %{"network" => %{"enabled" => true}}

      assert {:answer,
              %{"permissions" => %{"network" => %{"enabled" => true}}, "scope" => "session"}} =
               access(c, asked, "default", rules)

      # anything more asks again
      assert {:card, _} = access(c, %{"fileSystem" => %{"write" => ["/tmp/b"]}}, "default", rules)

      assert {:card, _} =
               access(c, %{"network" => %{"enabled" => true}}, "default", [
                 {:permissions, %{"fileSystem" => %{"write" => ["/tmp/a"]}}}
               ])
    end
  end

  describe "MCP elicitations" do
    defp elicit(c, meta, rules \\ []) do
      items = %{
        "m0" => %{"type" => "mcpToolCall", "id" => "m0", "server" => "other", "tool" => "nope"},
        "m1" => %{"type" => "mcpToolCall", "id" => "m1", "server" => "docs", "tool" => "search"}
      }

      Approvals.handle(
        "mcpServer/elicitation/request",
        5,
        %{
          "serverName" => "docs",
          "mode" => "form",
          "message" => "Allow the docs MCP server to run tool \"search\"?",
          "_meta" => meta
        },
        ctx(c, "default", %{items: items, rules: rules})
      )
    end

    test "a tool approval becomes a card named as Claude Code's are, with no action", c do
      meta = %{"codex_approval_kind" => "mcp_tool_call", "tool_params" => %{"q" => "x"}}
      assert {:card, card} = elicit(c, meta)
      assert card["id"] == "cx-ses-1-5"
      assert card["permission"] == "mcp__docs__search"
      assert card["patterns"] == []
      assert card["metadata"] == %{"input" => %{"q" => "x"}}
      refute Map.has_key?(card["metadata"], "action")
    end

    test "a remembered tool rule accepts it", c do
      meta = %{"codex_approval_kind" => "mcp_tool_call"}

      assert {:answer, %{"action" => "accept", "content" => nil}} =
               elicit(c, meta, [{:mcp_tool, "docs", "search"}])
    end

    test "any other elicitation is declined", c do
      for meta <- [%{}, nil, %{"codex_approval_kind" => "something_else"}] do
        assert {:answer, %{"action" => "decline", "content" => nil}} = elicit(c, meta)
      end
    end
  end

  describe "questions" do
    test "requestUserInput becomes a question card", c do
      params = %{
        "itemId" => "ask-1",
        "questions" => [
          %{
            "id" => "q1",
            "header" => "Pick",
            "question" => "Which database?",
            "isOther" => true,
            "isSecret" => false,
            "options" => [
              %{"label" => "SQLite", "description" => "local"},
              %{"label" => "Postgres", "description" => nil}
            ]
          }
        ]
      }

      assert {:question, request} =
               Approvals.handle("item/tool/requestUserInput", 0, params, ctx(c, "default"))

      assert request == %{
               "id" => "cx-ses-1-0",
               "tool" => %{"callID" => "ask-1"},
               "questions" => [
                 %{
                   "id" => "q1",
                   "question" => "Which database?",
                   "header" => "Pick",
                   "options" => [
                     %{"label" => "SQLite", "description" => "local"},
                     %{"label" => "Postgres", "description" => nil}
                   ],
                   "multiple" => false,
                   "custom" => true,
                   "secret" => false
                 }
               ]
             }
    end

    test "no questions is answered at once", c do
      assert {:answer, %{"answers" => %{}}} =
               Approvals.handle(
                 "item/tool/requestUserInput",
                 0,
                 %{"questions" => []},
                 ctx(c, "default")
               )
    end

    test "question_result/2" do
      request = %{"questions" => [%{"id" => "q1"}, %{"id" => "q2"}]}

      assert Approvals.question_result(request, {:answered, [["SQLite"], "Yes"]}) == %{
               "answers" => %{
                 "q1" => %{"answers" => ["SQLite"]},
                 "q2" => %{"answers" => ["Yes"]}
               }
             }

      assert Approvals.question_result(request, :rejected) == %{
               "answers" => %{
                 "q1" => %{"answers" => ["The user declined to answer."]},
                 "q2" => %{"answers" => ["The user declined to answer."]}
               }
             }

      assert %{"answers" => %{"q1" => %{"answers" => [text]}, "q2" => _}} =
               Approvals.question_result(request, :expired)

      assert text ==
               "The user hasn't answered yet. The question stays open in the channel. " <>
                 "End your turn now; their answer will reach you as a new message."
    end
  end

  test "an unknown server request is an error", c do
    assert {:error, -32601, message} = Approvals.handle("item/unknown", 0, %{}, ctx(c, "default"))
    assert is_binary(message)
  end

  describe "result/3" do
    test "Bash" do
      card = %{"permission" => "Bash", "metadata" => %{"action" => "command"}}

      params = %{
        "command" => "/bin/zsh -lc 'npm install x'",
        "proposedExecpolicyAmendment" => ["npm", "install"]
      }

      assert Approvals.result(card, params, :once) == {%{"decision" => "accept"}, nil}

      assert Approvals.result(card, params, :always) ==
               {%{"decision" => "acceptForSession"}, {:command, ["npm", "install"], false}}

      assert Approvals.result(card, params, :global) == {%{"decision" => "accept"}, nil}
      assert Approvals.result(card, params, :reject) == {%{"decision" => "decline"}, nil}
      assert Approvals.result(card, params, :expired) == {%{"decision" => "decline"}, nil}
    end

    test "Bash: Always remembers at least two words" do
      card = %{"permission" => "Bash", "metadata" => %{}}

      params = %{
        "command" => "/bin/zsh -lc 'rm -rf build'",
        "proposedExecpolicyAmendment" => ["rm"]
      }

      assert {_, {:command, ["rm", "-rf"], false}} = Approvals.result(card, params, :always)
    end

    test "a once-only card answers Always and Allow globally as Once, remembering nothing" do
      card = %{"permission" => "Bash", "metadata" => %{"once_only" => true}}
      params = %{"command" => "gh pr view", "proposedExecpolicyAmendment" => ["gh", "pr"]}

      for reply <- [:always, :global, :once] do
        assert Approvals.result(card, params, reply) == {%{"decision" => "accept"}, nil}
      end

      assert Approvals.result(card, params, :reject) == {%{"decision" => "decline"}, nil}
      assert Approvals.once_only?(card)
      refute Approvals.once_only?(%{"permission" => "Bash", "metadata" => %{}})
      assert Approvals.once_only(card, :global) == :once
      assert Approvals.once_only(%{"metadata" => %{}}, :global) == :global
    end

    test "file_change" do
      card = %{"permission" => "file_change"}
      assert Approvals.result(card, %{}, :once) == {%{"decision" => "accept"}, nil}

      assert Approvals.result(card, %{}, :always) ==
               {%{"decision" => "acceptForSession"}, :file_change}

      assert Approvals.result(card, %{}, :global) == {%{"decision" => "accept"}, nil}
      assert Approvals.result(card, %{}, :reject) == {%{"decision" => "decline"}, nil}
      assert Approvals.result(card, %{}, :expired) == {%{"decision" => "decline"}, nil}
    end

    test "permissions" do
      card = %{"permission" => "permissions"}
      profile = %{"network" => %{"enabled" => true}, "fileSystem" => %{"read" => ["/x"]}}
      params = %{"permissions" => profile}

      assert Approvals.result(card, params, :once) ==
               {%{"permissions" => profile, "scope" => "turn"}, nil}

      assert Approvals.result(card, params, :always) ==
               {%{"permissions" => profile, "scope" => "session"}, {:permissions, profile}}

      assert Approvals.result(card, params, :global) ==
               {%{"permissions" => profile, "scope" => "turn"}, nil}

      for reply <- [:reject, :expired] do
        assert Approvals.result(card, params, reply) ==
                 {%{"permissions" => %{}, "scope" => "turn"}, nil}
      end
    end

    test "MCP tools" do
      card = %{"permission" => "mcp__docs__search", "metadata" => %{"input" => %{}}}
      params = %{"serverName" => "docs"}
      accept = %{"action" => "accept", "content" => nil}

      assert Approvals.result(card, params, :once) == {accept, nil}
      assert Approvals.result(card, params, :global) == {accept, nil}
      assert Approvals.result(card, params, :always) == {accept, {:mcp_tool, "docs", "search"}}

      for reply <- [:reject, :expired] do
        assert Approvals.result(card, params, reply) ==
                 {%{"action" => "decline", "content" => nil}, nil}
      end
    end

    test "anything else declines" do
      assert Approvals.result(%{"permission" => "weird"}, %{}, :once) ==
               {%{"decision" => "decline"}, nil}
    end
  end

  describe "the Always store" do
    setup do
      ensure_store()
      sid = "ses-store-#{System.unique_integer([:positive])}"
      on_exit(fn -> Approvals.forget(sid) end)
      {:ok, sid: sid}
    end

    test "remember/2 and rules/1", %{sid: sid} do
      assert Approvals.rules(sid) == []
      assert Approvals.remember(sid, nil) == :ok
      assert Approvals.rules(sid) == []

      Approvals.remember(sid, {:command, ["npm", "install"], true})
      Approvals.remember(sid, :file_change)
      Approvals.remember(sid, {:command, ["npm", "install"], true})

      assert Approvals.rules(sid) == [{:command, ["npm", "install"], true}, :file_change]
    end

    test "rename/2 moves the rules to the new id, merging", %{sid: sid} do
      new = sid <> "-thread"
      on_exit(fn -> Approvals.forget(new) end)

      Approvals.remember(sid, :file_change)
      Approvals.remember(new, {:mcp_tool, "docs", "search"})
      Approvals.rename(sid, new)

      assert Approvals.rules(sid) == []
      assert Approvals.rules(new) == [{:mcp_tool, "docs", "search"}, :file_change]

      # renaming a session with no rules changes nothing
      Approvals.rename(sid <> "-none", new)
      assert length(Approvals.rules(new)) == 2
    end

    test "forget/1", %{sid: sid} do
      Approvals.remember(sid, :file_change)
      Approvals.forget(sid)
      assert Approvals.rules(sid) == []
    end
  end

  defp ensure_store do
    unless Process.whereis(Approvals), do: start_supervised!(Approvals)
    :ok
  end
end
