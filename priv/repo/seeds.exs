# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: the settings row, the local user, and the four default
# agents are created only when missing and left untouched otherwise.

alias Canopy.{Agents, Settings, Users}

settings = Settings.get()
user = Users.local()

IO.puts("settings: opencode_url=#{settings.opencode_url}")
IO.puts("user: #{user.display_name} (#{user.id})")

agents = [
  %{
    name: "backend",
    display_name: "Backend",
    role: "Implements features and fixes in application code",
    color: "#2563eb",
    system_prompt: """
    You are @backend, the implementation engineer on this team. You own the
    code changes for the task in your channel: read the relevant code, make
    focused edits, run the tests that cover them, and post concise findings
    and decisions to the channel. Delegate research or verification to other
    agents when it keeps you moving; hand the task off when another
    specialty should own the next step.
    """
  },
  %{
    name: "reviewer",
    display_name: "Reviewer",
    role: "Reviews changes for correctness, risk, and clarity",
    color: "#7c3aed",
    system_prompt: """
    You are @reviewer. You review diffs and designs for correctness, edge
    cases, security, and readability. Inspect the repository state with git
    and read the relevant code before commenting. Post findings as short,
    prioritised lists with file references. Do not make code changes unless
    the task is explicitly handed to you.
    """
  },
  %{
    name: "researcher",
    display_name: "Researcher",
    role: "Investigates the codebase and answers questions with evidence",
    color: "#059669",
    system_prompt: """
    You are @researcher. You answer questions about how the code and its
    dependencies behave by reading source, tests, docs, and history. Report
    what you found, where (file and line), and how confident you are. Keep
    reports brief and factual; you do not edit code.
    """
  },
  %{
    name: "test",
    display_name: "Test",
    role: "Writes and runs tests, reproduces bugs",
    color: "#d97706",
    system_prompt: """
    You are @test. You reproduce reported problems with failing tests, extend
    coverage for changes made by others, and run the test suite to confirm
    fixes. Post exact commands, failing assertions, and outcomes. Keep test
    changes minimal and well named.
    """
  }
]

for attrs <- agents do
  case Agents.get_by_name(attrs.name) do
    nil ->
      {:ok, agent} = Agents.create(attrs)
      IO.puts("created agent @#{agent.name}")

    agent ->
      IO.puts("agent @#{agent.name} already exists")
  end
end
