defmodule Canopy.OpenCode.MCPConfigTest do
  use ExUnit.Case, async: true

  alias Canopy.OpenCode.MCPConfig

  @fixtures Path.expand("../../support/mcp_fixtures/opencode", __DIR__)

  # outer/ (an opencode.json above the git root)
  #   root/ (git root, opencode.json, .opencode/opencode.json)
  #     sub/pkg/ (opencode.json)
  setup do
    outer = Path.join(System.tmp_dir!(), "canopy-oc-#{System.unique_integer([:positive])}")
    root = Path.join(outer, "root")
    File.mkdir_p!(Path.join([root, "sub", "pkg"]))
    File.mkdir_p!(Path.join([root, ".opencode"]))
    File.mkdir_p!(Path.join(root, ".git"))
    on_exit(fn -> File.rm_rf!(outer) end)

    File.cp!(
      Path.join([@fixtures, "outside", "opencode.json"]),
      Path.join(outer, "opencode.json")
    )

    File.cp!(Path.join([@fixtures, "repo", "opencode.json"]), Path.join(root, "opencode.json"))

    File.cp!(
      Path.join([@fixtures, "repo", "sub", "pkg", "opencode.json"]),
      Path.join([root, "sub", "pkg", "opencode.json"])
    )

    File.cp!(
      Path.join([@fixtures, "dot_opencode", "opencode.json"]),
      Path.join([root, ".opencode", "opencode.json"])
    )

    opts = [config_home: Path.join(@fixtures, "global"), opencode_config: nil]
    {:ok, root: root, opts: opts}
  end

  test "merges global, project and .opencode files, later files winning", %{
    root: root,
    opts: opts
  } do
    %{servers: servers, errors: []} = MCPConfig.sources(root, opts)

    assert Map.keys(servers) |> Enum.sort() == ["canopy", "db", "search", "shared", "tracker"]

    # JSONC global file, with the secret only referenced
    assert %{kind: :global, config: %{"headers" => %{"Authorization" => "Bearer {env:API_KEY}"}}} =
             servers["search"]

    assert servers["db"].kind == :project
    assert servers["db"].path == Path.join(root, "opencode.json")

    # `.opencode/opencode.json` disables the global server and keeps its command
    assert %{
             kind: :project,
             path: path,
             config: %{"enabled" => false, "command" => ["shared-mcp", "--verbose"]}
           } = servers["shared"]

    assert path == Path.join([root, ".opencode", "opencode.json"])
  end

  test "searches upward from the repository and stops at the git root", %{root: root, opts: opts} do
    %{servers: servers} = MCPConfig.sources(Path.join([root, "sub", "pkg"]), opts)

    assert servers["pkg-only"].kind == :project
    assert servers["db"].path == Path.join(root, "opencode.json")
    refute Map.has_key?(servers, "above-git-root")
  end

  test "OPENCODE_CONFIG is read after the global files", %{root: root, opts: opts} do
    custom = Path.join(Path.dirname(root), "custom.json")
    File.write!(custom, ~s({"mcp": {"custom": {"type": "remote", "url": "https://c.example"}}}))

    %{servers: servers} = MCPConfig.sources(root, Keyword.put(opts, :opencode_config, custom))
    assert %{kind: :global, path: ^custom} = servers["custom"]
  end

  test "a broken file becomes an error, not a crash", %{root: root, opts: opts} do
    File.write!(Path.join(root, "opencode.jsonc"), "{ \"mcp\": ")

    %{servers: servers, errors: [error]} = MCPConfig.sources(root, opts)
    assert error =~ "opencode.jsonc: invalid JSON"
    assert Map.has_key?(servers, "db")
  end

  describe "strip_jsonc/1" do
    test "drops comments and trailing commas but leaves strings alone" do
      text = """
      {
        // line
        "a": "http://x.example/y", /* block */
        "b": "// not a comment, /* nor this */",
        "c": [1, 2,],
        "d": "quote \\" inside",
      }
      """

      assert JSON.decode!(MCPConfig.strip_jsonc(text)) == %{
               "a" => "http://x.example/y",
               "b" => "// not a comment, /* nor this */",
               "c" => [1, 2],
               "d" => "quote \" inside"
             }
    end
  end
end
