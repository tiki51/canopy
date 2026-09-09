defmodule Canopy.Runtime.CommandsTest do
  use ExUnit.Case, async: true

  alias Canopy.Runtime.Commands

  test "plain text and unknown slashes are text" do
    assert Commands.parse("hello @backend") == :text
    assert Commands.parse("/lib/foo.ex is broken") == :text
    assert Commands.parse("/unknown thing") == :text
    assert Commands.parse("") == :text
  end

  test "handoff and delegate parse target and text" do
    assert {:command, :handoff, "database", "needs schema work"} =
             Commands.parse("/handoff @database needs schema work")

    assert {:command, :handoff, "database", "needs schema work"} =
             Commands.parse("  /HANDOFF database   needs schema work  ")

    assert {:command, :delegate, "researcher", "trace every enqueue path\nand report back"} =
             Commands.parse("/delegate @researcher trace every enqueue path\nand report back")
  end

  test "missing target or text is a usage error" do
    assert {:error, "usage: /handoff" <> _} = Commands.parse("/handoff")
    assert {:error, "usage: /handoff" <> _} = Commands.parse("/handoff @database")
    assert {:error, "usage: /delegate" <> _} = Commands.parse("/delegate")
  end
end
