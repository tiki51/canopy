defmodule Canopy.EngineTest do
  # changes the global `:engines` config
  use ExUnit.Case, async: false

  alias Canopy.Engine

  setup do
    engines = Application.get_env(:canopy, :engines)
    on_exit(fn -> Application.put_env(:canopy, :engines, engines) end)
    :ok
  end

  defp configure(engines), do: Application.put_env(:canopy, :engines, engines)

  describe "names/0" do
    test "Claude Code, Codex, OpenCode, whatever the config map's order" do
      configure(%{"opencode" => OC, "codex" => CX, "claude_code" => CC})
      assert Engine.names() == ["claude_code", "codex", "opencode"]

      configure(Map.new([{"codex", CX}, {"opencode", OC}, {"claude_code", CC}]))
      assert Engine.names() == ["claude_code", "codex", "opencode"]
    end

    test "an engine missing from the config is left out, the order kept" do
      configure(%{"opencode" => OC, "claude_code" => CC})
      assert Engine.names() == ["claude_code", "opencode"]

      configure(%{"opencode" => OC, "codex" => CX})
      assert Engine.names() == ["codex", "opencode"]

      configure(%{})
      assert Engine.names() == []
    end

    test "a configured engine this module doesn't know comes last, sorted" do
      configure(%{"zeta" => Z, "opencode" => OC, "alpha" => A, "claude_code" => CC})
      assert Engine.names() == ["claude_code", "opencode", "alpha", "zeta"]
    end
  end

  test "label/1 names the three engines, and falls back to the name" do
    assert Engine.label("claude_code") == "Claude Code"
    assert Engine.label("codex") == "Codex"
    assert Engine.label("opencode") == "OpenCode"
    assert Engine.label("warp") == "warp"
  end

  test "options/0 is {label, name} in names/0 order" do
    configure(%{"opencode" => OC, "codex" => CX, "claude_code" => CC})

    assert Engine.options() == [
             {"Claude Code", "claude_code"},
             {"Codex", "codex"},
             {"OpenCode", "opencode"}
           ]

    configure(%{"opencode" => OC})
    assert Engine.options() == [{"OpenCode", "opencode"}]
  end

  describe "sort_by_engine/2" do
    test "orders by the key's position in names/0" do
      configure(%{"opencode" => OC, "codex" => CX, "claude_code" => CC})

      rows = [
        %{engine: "opencode", n: 1},
        %{engine: "claude_code", n: 2},
        %{engine: "codex", n: 3}
      ]

      assert Engine.sort_by_engine(rows, & &1.engine) |> Enum.map(& &1.n) == [2, 3, 1]

      # a map keyed by engine
      inventory = %{"opencode" => [:a], "codex" => [:b], "claude_code" => [:c]}

      assert Engine.sort_by_engine(inventory, &elem(&1, 0)) ==
               [{"claude_code", [:c]}, {"codex", [:b]}, {"opencode", [:a]}]
    end

    test "unknown or unconfigured keys come last, in their original order" do
      configure(%{"opencode" => OC, "claude_code" => CC})

      assert Engine.sort_by_engine(~w(warp opencode codex claude_code nope), & &1) ==
               ~w(claude_code opencode warp codex nope)

      assert Engine.sort_by_engine([], & &1) == []
    end
  end
end
