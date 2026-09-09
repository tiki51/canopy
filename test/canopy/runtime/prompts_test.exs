defmodule Canopy.Runtime.PromptsTest do
  use ExUnit.Case, async: true

  alias Canopy.Runtime.Prompts

  test "system prompt substitutes identity and appends the role prompt" do
    agent = %{
      name: "backend",
      display_name: "Backend",
      role: "Primary implementation",
      system_prompt: "Prefer small diffs."
    }

    text = Prompts.system(agent, %{name: "payments"}, %{path: "/repo"})
    assert text =~ "You are Backend (@backend)"
    assert text =~ "channel #payments"
    assert text =~ "/repo"
    assert text =~ "Role: Primary implementation"
    assert String.ends_with?(text, "Prefer small diffs.")
    refute text =~ "{{"
  end

  test "system prompt works without a role prompt" do
    agent = %{name: "x", display_name: nil, role: nil, system_prompt: nil}
    text = Prompts.system(agent, %{name: "c"}, %{path: "/r"})
    assert text =~ "You are x (@x)"
    refute text =~ "{{"
  end

  test "wake prompts never contain message bodies, only ids" do
    text =
      Prompts.new_message(%{channel: "c", sender: "Steven", message_id: "msg_42", thread?: false})

    assert text =~ "msg_42"
    refute text =~ "body"
  end
end
