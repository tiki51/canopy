defmodule CanopyWeb.FallbackOptionsTest do
  use ExUnit.Case, async: true

  alias CanopyWeb.FallbackOptions

  @ready %{
    "claude_code" => {:ok, ~w(opus sonnet)},
    "codex" => {:ok, ~w(gpt-5-codex gpt-5)},
    "opencode" => {:ok, ~w(anthropic/claude-sonnet-4-5)}
  }

  defp keys(group), do: Enum.map(group, & &1[:key])

  test "groups come in engine order; the primary's own models pause with it" do
    assert [
             {"Claude Code", claude},
             {"Codex", codex},
             {"OpenCode", opencode}
           ] = FallbackOptions.options("claude_code", @ready, nil)

    assert keys(claude) == ["opus (pauses with Claude Code)", "sonnet (pauses with Claude Code)"]
    assert Enum.map(claude, & &1[:value]) == ["claude_code:opus", "claude_code:sonnet"]
    assert keys(codex) == ["gpt-5-codex", "gpt-5"]

    assert opencode == [
             [key: "anthropic/claude-sonnet-4-5", value: "opencode:anthropic/claude-sonnet-4-5"]
           ]

    assert [
             _,
             _,
             {"OpenCode", [[key: "anthropic/claude-sonnet-4-5 (pauses with OpenCode)"] ++ _]}
           ] =
             FallbackOptions.options("opencode", @ready, nil)
  end

  test "the primary model is left out" do
    [{"Claude Code", claude} | _] = FallbackOptions.options("claude_code", @ready, nil, "opus")
    assert keys(claude) == ["sonnet (pauses with Claude Code)"]

    # a group left empty is dropped
    assert [{"Claude Code", _}, {"Codex", _}] =
             FallbackOptions.options("opencode", @ready, nil, "anthropic/claude-sonnet-4-5")
  end

  test "an engine that isn't ready has a disabled note" do
    sources = %{"claude_code" => :not_found, "codex" => :loading, "opencode" => :error}

    assert [
             {"Claude Code", [claude]},
             {"Codex", [codex]},
             {"OpenCode", [opencode]}
           ] = FallbackOptions.options("codex", sources, nil)

    assert claude == [
             key: "Claude Code not found: check it in Settings",
             value: "unavailable:claude_code",
             disabled: true
           ]

    assert codex[:key] == "Loading Codex's models…"
    assert codex[:disabled]
    assert opencode[:key] == "Not running: start opencode serve to list its models"

    assert [_, {"Codex", [errored]}, _] =
             FallbackOptions.options("claude_code", %{sources | "codex" => :error}, nil)

    assert errored[:key] == "Couldn't read Codex's models: check it in Settings"
  end

  test "a saved value the lists don't offer stays, marked saved" do
    sources = %{@ready | "codex" => :loading}

    assert [_, {"Codex", [note, saved]}, _] =
             FallbackOptions.options("claude_code", sources, "codex:gpt-5-codex")

    assert note[:disabled]
    assert saved == [key: "gpt-5-codex (saved)", value: "codex:gpt-5-codex"]

    assert [{"Claude Code", claude} | _] =
             FallbackOptions.options("claude_code", @ready, "claude_code:haiku")

    assert List.last(claude) == [
             key: "haiku (saved, pauses with Claude Code)",
             value: "claude_code:haiku"
           ]

    # offered values aren't repeated
    assert [_, {"Codex", codex}, _] =
             FallbackOptions.options("claude_code", @ready, "codex:gpt-5")

    assert keys(codex) == ["gpt-5-codex", "gpt-5"]
  end

  test "sources/1 reads what a page loaded" do
    assigns = %{
      claude_found: true,
      codex_found: true,
      codex_models: [%{id: "gpt-5-codex"}],
      codex_models_state: :ok,
      providers: [%{id: "anthropic", models: ["claude-sonnet-4-5"]}],
      providers_state: :ok
    }

    assert FallbackOptions.sources(assigns) == %{
             "claude_code" => {:ok, Canopy.Agents.Agent.claude_models()},
             "codex" => {:ok, ["gpt-5-codex"]},
             "opencode" => {:ok, ["anthropic/claude-sonnet-4-5"]}
           }

    assert %{"claude_code" => :not_found, "codex" => :not_found, "opencode" => :loading} =
             FallbackOptions.sources(%{
               assigns
               | claude_found: false,
                 codex_found: false,
                 providers_state: :loading
             })

    # nil: not started yet, so still loading rather than an error
    assert %{"codex" => :loading, "opencode" => :loading} =
             FallbackOptions.sources(%{assigns | codex_models_state: nil, providers_state: nil})

    assert %{"codex" => :error, "opencode" => :error} =
             FallbackOptions.sources(%{
               assigns
               | codex_models_state: {:error, "boom"},
                 providers_state: :error
             })
  end
end
