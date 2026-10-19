defmodule Canopy.Seeds do
  @moduledoc """
  Creates Canopy's initial settings, user, default agents, starter team, and starter playbooks.

  `run/0` does the work and returns a report; it does no IO, so Settings can
  show it (`Canopy.Environment.seed/0`). `print/1` writes the report as the
  lines the command line has always printed (`scripts/smoke-release.sh` and
  the Homebrew formula's test match `created agent @backend` and
  `agent @backend already exists`), and `run_cli!/0` does both and raises on
  a failure, so `mix run priv/repo/seeds.exs` and `canopy seed` exit non-zero.
  """

  alias Canopy.{Agents, Settings, Teams, Users}

  defmodule Error do
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: "seeder stopped: #{reason}"
  end

  @typedoc "One starter, in a report."
  @type item :: %{kind: :agent | :team | :playbook, name: String.t()}

  @typedoc "What a run created, found already there, or skipped."
  @type report :: %{
          created: [item()],
          existing: [item()],
          skipped: [item()],
          cost_auditor: {:assigned | :unchanged | :none, String.t() | nil} | nil,
          settings: %{opencode_url: String.t() | nil} | nil,
          user: %{id: String.t(), display_name: String.t()} | nil
        }

  @doc """
  Seeds missing defaults without changing existing records.

  Returns `{:ok, report}`, or `{:error, reason, partial}` when a step fails;
  whatever was created before the failure is kept and is in `partial`.
  """
  @spec run() :: {:ok, report()} | {:error, String.t(), report()}
  def run do
    # Each step adds to the report as it goes, so a failure still reports what
    # was done before it.
    Process.put(__MODULE__, empty_report())

    try do
      seed_settings_and_user()
      seed_agents()
      seed_teams()
      seed_playbooks()
      seed_cost_auditor()
      {:ok, finish(Process.get(__MODULE__))}
    rescue
      e -> {:error, Canopy.Environment.error_message(e), finish(Process.get(__MODULE__))}
    after
      Process.delete(__MODULE__)
    end
  end

  @doc "Prints a `run/0` result as the seeder's lines and returns it."
  def print({:ok, report} = result) do
    print_report(report)
    result
  end

  def print({:error, reason, partial} = result) do
    print_report(partial)
    IO.puts("seeder stopped: #{reason}")
    result
  end

  @doc "`run/0` and `print/1` for the command line; raises `Canopy.Seeds.Error` on a failure."
  def run_cli! do
    case run() |> print() do
      {:ok, report} -> report
      {:error, reason, _partial} -> raise Error, reason: reason
    end
  end

  defp print_report(report) do
    if s = report.settings, do: IO.puts("settings: opencode_url=#{s.opencode_url}")
    if u = report.user, do: IO.puts("user: #{u.display_name} (#{u.id})")

    report
    |> items_in_seed_order()
    |> Enum.each(fn {bucket, item} -> IO.puts(line(bucket, item)) end)

    case report.cost_auditor do
      {:assigned, name} -> IO.puts("assigned @#{name} as the cost auditor")
      _ -> :ok
    end
  end

  defp empty_report do
    %{
      created: [],
      existing: [],
      skipped: [],
      cost_auditor: nil,
      settings: nil,
      user: nil
    }
  end

  # Lists were built newest first.
  defp finish(report) do
    %{
      report
      | created: Enum.reverse(report.created),
        existing: Enum.reverse(report.existing),
        skipped: Enum.reverse(report.skipped)
    }
  end

  # The report keeps created and existing apart; the lines interleave them as
  # the seeder met them: agents in starter order, then teams, then playbooks in
  # seed order.
  defp items_in_seed_order(report) do
    rank = %{
      agent: agent_names() |> Enum.with_index() |> Map.new(),
      playbook: Canopy.Playbooks.seed_names() |> Enum.with_index() |> Map.new()
    }

    kind_rank = %{agent: 0, team: 1, playbook: 2}

    [:created, :existing, :skipped]
    |> Enum.flat_map(fn bucket -> Enum.map(Map.fetch!(report, bucket), &{bucket, &1}) end)
    |> Enum.with_index()
    |> Enum.sort_by(fn {{_bucket, item}, i} ->
      {kind_rank[item.kind], Map.get(rank[item.kind] || %{}, item.name, i)}
    end)
    |> Enum.map(fn {pair, _i} -> pair end)
  end

  defp line(:created, %{kind: :playbook, name: name}), do: "created playbook #{name}"
  defp line(:existing, %{kind: :playbook, name: name}), do: "playbook #{name} already exists"
  defp line(:created, %{kind: kind, name: name}), do: "created #{kind} @#{name}"
  defp line(:existing, %{kind: kind, name: name}), do: "#{kind} @#{name} already exists"
  defp line(:skipped, %{kind: kind, name: name}), do: "skipped #{kind} @#{name}"

  defp record(bucket, kind, name) do
    report = Process.get(__MODULE__)

    Process.put(__MODULE__, %{
      report
      | bucket => [%{kind: kind, name: name} | Map.fetch!(report, bucket)]
    })
  end

  defp put_report(key, value),
    do: Process.put(__MODULE__, %{Process.get(__MODULE__) | key => value})

  defp seed_settings_and_user do
    settings = Settings.get()
    put_report(:settings, %{opencode_url: settings.opencode_url})

    user = Users.local()
    put_report(:user, %{id: user.id, display_name: user.display_name})
  end

  defp seed_agents do
    for attrs <- starter_agents() do
      case Agents.get_by_name(attrs.name) do
        nil ->
          case Agents.create(attrs) do
            {:ok, agent} ->
              record(:created, :agent, agent.name)

            {:error, changeset} ->
              raise "agent @#{attrs.name}: #{changeset_errors(changeset)}"
          end

        agent ->
          record(:existing, :agent, agent.name)
      end
    end
  end

  # Created when missing, from whichever of its agents exist; an existing team
  # is never edited.
  defp seed_teams do
    for %{name: name, members: names, lead: lead} = attrs <- starter_teams() do
      agents = Enum.flat_map(names, &List.wrap(Agents.get_by_name(&1)))
      lead = Enum.find(agents, &(&1.name == lead)) || List.first(agents)

      cond do
        Teams.get_by_name(name) ->
          record(:existing, :team, name)

        Agents.get_by_name(name) || is_nil(lead) ->
          record(:skipped, :team, name)

        true ->
          {:ok, team} =
            attrs
            |> Map.drop([:members, :lead])
            |> Map.merge(%{agent_ids: Enum.map(agents, & &1.id), lead_agent_id: lead.id})
            |> Teams.create()

          record(:created, :team, team.name)
      end
    end
  end

  # Starter playbooks, created when missing by name; an existing one is never edited.
  defp seed_playbooks do
    for result <- Canopy.Playbooks.seed() do
      case result do
        {:created, name} -> record(:created, :playbook, name)
        {:exists, name} -> record(:existing, :playbook, name)
      end
    end
  end

  # The cost auditor answers "Request audit" on the Costs page.
  defp seed_cost_auditor do
    result =
      case {Canopy.Costs.Auditor.agent(), Agents.get_by_name("finops")} do
        {nil, %{id: id, name: name}} ->
          {:ok, _} = Canopy.Costs.Auditor.assign(id)
          {:assigned, name}

        {%{name: name}, _} ->
          {:unchanged, name}

        {nil, nil} ->
          {:none, nil}
      end

    put_report(:cost_auditor, result)
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp starter_teams do
    [
      %{
        name: "bugfix-team",
        display_name: "Bugfix team",
        description: "Reproduces, fixes, tests, and reviews bugs",
        # the implementation engineer owns the fix, so it owns the team's channels
        lead: "backend",
        members: ~w(frontend backend test reviewer)
      }
    ]
  end

  @doc "The names of the starter agents."
  def agent_names, do: Enum.map(starter_agents(), & &1.name)

  # The 13 starter agents are gallery templates marked `seed: true`
  # (priv/templates/agents), so the gallery can re-add one that was changed or
  # retired. They get no engine and no model of their own: they follow the
  # default engine and its default model from Settings. Their `mode` sets
  # every engine's reach (OpenCode's agent, the permission mode Claude Code
  # and Codex read), so a `plan` starter is read-only whichever engine is the
  # default.
  defp starter_agents do
    for template <- Canopy.Templates.Gallery.seed_agents() do
      {attrs, _notices} = Canopy.Templates.AgentTemplate.attrs(template, "opencode")

      attrs
      |> Map.take([
        :name,
        :display_name,
        :role,
        :group,
        :color,
        :system_prompt,
        :opencode_agent,
        :permission_mode
      ])
      |> Map.put(:engine, nil)
    end
  end
end
