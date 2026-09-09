defmodule Canopy.TasksTest do
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.{Tasks, Timeline}

  test "update/3 records task_updated with the changes" do
    %{channel: channel, task: task, agent: agent} = scenario()
    Timeline.subscribe(channel.id)

    assert {:ok, task} =
             Tasks.update(task, %{status: "working", result: "started"}, agent_id: agent.id)

    assert task.status == "working"

    assert_receive {:timeline, %Timeline.Event{event_type: "task_updated"} = event}
    assert event.ref_id == task.id
    assert event.agent.id == agent.id
    assert event.payload["changes"] == %{"status" => "working", "result" => "started"}
    assert event.payload["status"] == "working"

    assert {:error, changeset} = Tasks.update(task, %{status: "bogus"})
    assert %{status: [_]} = errors_on(changeset)
    assert Tasks.for_channel(channel.id).status == "working"
  end
end
