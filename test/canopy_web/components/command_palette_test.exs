defmodule CanopyWeb.CommandPaletteTest do
  use ExUnit.Case, async: true

  alias Canopy.Agents.Agent
  alias Canopy.Channels.Channel
  alias Canopy.Repositories.Repository
  alias Canopy.Runtime.Commands
  alias CanopyWeb.CommandPalette

  defp repository(id, name, channels),
    do: Map.put(%Repository{id: id, name: name}, :channels, channels)

  describe "items/4" do
    setup do
      backend = %Agent{
        id: "agt_b",
        name: "backend",
        role: "Backend engineer",
        group: "Engineering"
      }

      qa = %Agent{id: "agt_q", name: "qa", role: nil, group: nil}

      open = %Channel{id: "ch_1", name: "payment-retries", status: "open", repository_id: "rep_1"}
      old = %Channel{id: "ch_2", name: "pay-v1", status: "archived", repository_id: "rep_1"}
      acme = repository("rep_1", "acme", [open, old])

      dm = %Channel{
        id: "ch_dm",
        kind: "dm",
        name: "dm-backend",
        status: "open",
        repository_id: "rep_1",
        repository: acme,
        agents: [backend]
      }

      palette = %{
        teams: [%{id: "tm_1", name: "bugfix-team"}],
        playbooks: [%{id: "pb_1", name: "bug-fix"}]
      }

      items = CommandPalette.items([acme], [dm], [backend, qa], palette)
      %{items: items}
    end

    test "channels carry their repository and whether they are archived", %{items: items} do
      assert %{
               t: "channel",
               name: "payment-retries",
               repo: "acme",
               repo_id: "rep_1",
               archived: false
             } =
               Enum.find(items, &(&1.id == "ch_1"))

      assert %{t: "channel", archived: true} = Enum.find(items, &(&1.id == "ch_2"))
    end

    test "DMs are listed by their label, not as channels", %{items: items} do
      assert [%{t: "dm", label: "@backend", repo: "acme", archived: false}] =
               Enum.filter(items, &(&1.id == "ch_dm"))
    end

    test "agents carry their role and group; teams, repositories and playbooks are listed",
         %{items: items} do
      assert %{t: "agent", name: "backend", role: "Backend engineer", group: "Engineering"} =
               Enum.find(items, &(&1.id == "agt_b"))

      assert %{t: "agent", role: nil, group: nil} = Enum.find(items, &(&1.id == "agt_q"))
      assert %{t: "team", name: "bugfix-team"} = Enum.find(items, &(&1.id == "tm_1"))
      assert %{t: "repo", name: "acme"} = Enum.find(items, &(&1.id == "rep_1"))
      assert %{t: "playbook", name: "bug-fix"} = Enum.find(items, &(&1.id == "pb_1"))
    end

    test "the palette lists are optional" do
      assert [%{t: "repo"}] = CommandPalette.items([repository("rep_9", "empty", [])], [], [])
    end
  end

  test "badges/2 merges unread and attention and drops zero entries" do
    unread = %{"ch_1" => %{count: 3, mentions: 1}, "ch_2" => %{count: 0, mentions: 0}}

    attention = %{
      "ch_1" => %{questions: 1, permissions: 1, approvals: 0, playbook: false},
      "ch_3" => %{questions: 0, permissions: 0, approvals: 1, playbook: true},
      "ch_4" => %{questions: 0, permissions: 0, approvals: 0, playbook: true}
    }

    assert CommandPalette.badges(unread, attention) == %{"ch_1" => [3, 1, 2], "ch_3" => [0, 0, 1]}
  end

  test "context/1 says where you are" do
    assert CommandPalette.context(%{
             current_channel_id: "ch_1",
             current_repository_id: "rep_1",
             current_path: "/channels/ch_1",
             hold: "Insufficient balance"
           }) == %{channel_id: "ch_1", repo_id: "rep_1", path: "/channels/ch_1", hold: true}

    assert CommandPalette.context(%{current_path: "/agents", hold: nil}) ==
             %{channel_id: nil, repo_id: nil, path: "/agents", hold: false}
  end

  describe "Commands.catalog/0" do
    test "covers every command once, with /invite as an alias of /i" do
      names = Enum.flat_map(Commands.catalog(), &[&1.name | &1.aliases])
      assert Enum.sort(names) == Commands.names()

      assert %{name: "i", aliases: ["invite"], dm?: false} =
               Enum.find(Commands.catalog(), &(&1.name == "i"))
    end

    test "help/0 is built from it, and every prefill parses as its own command" do
      for command <- Commands.catalog() do
        assert Commands.help() =~ command.hint

        if command.prefill do
          assert String.starts_with?(command.prefill, "/" <> command.name <> " ")
        else
          assert {:command, :stop, _, _} = Commands.parse(command.usage)
        end
      end

      assert [%{name: "i"} | _] = CommandPalette.commands()
      assert Enum.all?(CommandPalette.commands(), &Map.has_key?(&1, :dm))
    end
  end
end
