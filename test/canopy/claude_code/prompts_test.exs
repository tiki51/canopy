defmodule Canopy.ClaudeCode.PromptsTest do
  @moduledoc "The open permission and question prompts of Claude Code sessions."
  use Canopy.DataCase, async: false

  alias Canopy.ClaudeCode.Prompts

  setup do
    sid = Ecto.UUID.generate()
    on_exit(fn -> Prompts.drop_session(sid) end)
    {:ok, sid: sid, id: "p-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  test "a session is waiting from open until its prompt is answered", %{sid: sid, id: id} do
    refute Prompts.waiting?(sid)
    :ok = Prompts.open(id, :question, sid, %{"id" => id})
    assert Prompts.waiting?(sid)
    refute Prompts.waiting?(Ecto.UUID.generate())

    :ok = Prompts.answer(id, :rejected)
    refute Prompts.waiting?(sid)
    assert {:ok, :rejected} = Prompts.await(id)
  end

  test "a session stops waiting when its prompt expires", %{sid: sid, id: id} do
    :ok = Prompts.open(id, :permission, sid, %{"id" => id})
    assert {:error, :timeout} = Prompts.await(id, 50)
    refute Prompts.waiting?(sid)
    assert Prompts.answer(id, :once) == {:error, :gone}
  end

  test "dropping a session releases what still waits and forgets its prompts",
       %{sid: sid, id: id} do
    :ok = Prompts.open(id, :question, sid, %{"id" => id})
    waiter = Task.async(fn -> Prompts.await(id, 60_000) end)

    :ok = Prompts.drop_session(sid)
    assert Task.await(waiter) == {:error, :gone}
    refute Prompts.waiting?(sid)
    assert Prompts.pending() |> Enum.filter(&(&1.session_id == sid)) == []
    assert Prompts.answer(id, :rejected) == {:error, :gone}
  end

  test "the question wait comes from Settings, capped by the prompt timeout" do
    previous = Application.get_env(:canopy, :claude_code)
    on_exit(fn -> Application.put_env(:canopy, :claude_code, previous) end)

    Application.put_env(:canopy, :claude_code, Keyword.delete(previous || [], :question_wait_ms))
    assert Prompts.question_timeout_ms() == :timer.minutes(10)

    Application.put_env(
      :canopy,
      :claude_code,
      Keyword.put(previous || [], :prompt_timeout_ms, 500)
    )

    assert Prompts.question_timeout_ms() == 500
  end
end
