# Seeds the "Reports" workspace the canopy_site captures play their story in
# (e2e/tests/site-shots.spec.ts, site-video.spec.ts). Run against the
# Playwright database only:
#
#     SITE=1 CANOPY_SEED=e2e/bin/seed-reports.exs bash e2e/bin/server.sh
#
# The story is one Feature build playbook run, "Add a CSV export to the
# Reports page", started from the Start page in the browser. The coordinator
# (@project-manager) and the roster (@designer, @frontend, @backend, @test,
# @reviewer) run on the fake Claude Code (e2e/fake-claude), which scripts
# every turn. This seed only sets the stage: the cast, the acme-reports
# repository, two quiet channels for the sidebar, and some memory. It never
# wakes an agent. REPORTS_DIR moves the repository (default: tmp/).
#
# Not seed-acme.exs: the user guide, onboarding and command-palette specs
# depend on that one, billing story and all.

import Ecto.Query

alias Canopy.{Agents, Channels, Memory, Messages, Repo, Repositories, Settings, Users}
alias Canopy.Messages.Message
alias Canopy.Timeline.Event

root = File.cwd!()
repos_dir = System.get_env("REPORTS_DIR") || Path.join(root, "tmp")
now = DateTime.utc_now()

days_ago = fn days, hour ->
  now
  |> DateTime.add(-days * 86_400, :second)
  |> Map.merge(%{hour: hour, minute: :rand.uniform(59), second: :rand.uniform(59)})
end

# `days` days back, `minutes` before now: site captures move the server's clock
# (a POSIX TZ that reads 10:40 at launch), so only times relative to now show
# as a sensible time of day.
before = fn days, minutes -> DateTime.add(now, -days * 86_400 - minutes * 60, :second) end

:rand.seed(:exsss, {2026, 10, 14})

# -- The local user ---------------------------------------------------------------

# A playbook run is a long run of agent-to-agent wakes between the user's
# presses; the chatter budget stays on, high enough not to pause it.
{:ok, _} = Settings.update(%{user_display_name: "Priya", chatter_limit: 100})
user = Users.local()
user = user |> Ecto.Changeset.change(display_name: "Priya") |> Repo.update!()

# -- The repository -----------------------------------------------------------------

reports_py = """
\"\"\"Report queries behind the Reports page.\"\"\"
from dataclasses import dataclass

from acme.reports import store


@dataclass
class Report:
    id: str
    title: str
    columns: list[str]
    rows: list[list[object]]


def build_report(report_id: str, filters: dict) -> Report:
    spec = store.report_spec(report_id)
    rows = store.query(spec.sql, filters)
    return Report(id=report_id, title=spec.title, columns=spec.columns, rows=rows)
"""

api_py = """
from flask import Blueprint, jsonify, request

from acme.reports import reports

bp = Blueprint("reports", __name__, url_prefix="/api/reports")


@bp.get("/<report_id>")
def show(report_id: str):
    report = reports.build_report(report_id, request.args.to_dict())
    return jsonify(title=report.title, columns=report.columns, rows=report.rows)
"""

store_py = """
\"\"\"Report specs and the read-only query runner.\"\"\"
from acme.db import readonly

SPECS = {
    "weekly-signups": {
        "title": "Weekly signups",
        "columns": ["Week", "Region", "Signups", "Activated", "Rate"],
        "sql": "select * from report_weekly_signups where week >= :since",
    },
}


def report_spec(report_id: str):
    return readonly.spec(SPECS[report_id])


def query(sql: str, filters: dict) -> list[list[object]]:
    return readonly.rows(sql, filters)
"""

test_reports_py = """
from acme.reports import reports


def test_build_report_has_the_spec_columns(signups_store):
    report = reports.build_report("weekly-signups", {})
    assert report.columns == ["Week", "Region", "Signups", "Activated", "Rate"]
"""

data_table_tsx = """
import type { ReactNode } from "react";

type Props = {
  title: string;
  columns: string[];
  rows: unknown[][];
  /** Filters and actions, shown above the table. */
  toolbar?: ReactNode;
};

export function DataTable({ title, columns, rows, toolbar }: Props) {
  return (
    <section className="data-table">
      <header>
        <h1>{title}</h1>
      </header>
      {toolbar && <div className="data-table-toolbar">{toolbar}</div>}
      <table>
        <thead>
          <tr>{columns.map((c) => <th key={c}>{c}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={i}>{row.map((cell, j) => <td key={j}>{String(cell)}</td>)}</tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
"""

reports_page_tsx = """
import { DataTable } from "../components/DataTable";
import { FilterChips } from "../components/FilterChips";
import { useReport } from "../api/reports";

export function ReportsPage({ reportId }: { reportId: string }) {
  const { report, filters, setFilters } = useReport(reportId);

  return (
    <DataTable
      title={report.title}
      columns={report.columns}
      rows={report.rows}
      toolbar={<FilterChips value={filters} onChange={setFilters} />}
    />
  );
}
"""

reports_api_ts = """
import { useEffect, useState } from "react";

export type Filters = Record<string, string>;
export type Report = { title: string; columns: string[]; rows: unknown[][] };

const query = (filters: Filters) => new URLSearchParams(filters).toString();

export function useReport(reportId: string) {
  const [filters, setFilters] = useState<Filters>({ since: "4w" });
  const [report, setReport] = useState<Report>({ title: "", columns: [], rows: [] });

  useEffect(() => {
    fetch(`/api/reports/${reportId}?${query(filters)}`)
      .then((r) => r.json())
      .then(setReport);
  }, [reportId, filters]);

  return { report, filters, setFilters };
}
"""

make_repo = fn name, files ->
  path = Path.join(repos_dir, name)
  File.rm_rf!(path)
  File.mkdir_p!(path)

  for {rel, body} <- files do
    full = Path.join(path, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end

  git = fn args ->
    {_, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
  end

  git.(["init", "-q", "-b", "main"])
  git.(["add", "-A"])

  git.([
    "-c",
    "user.email=dev@acme.example",
    "-c",
    "user.name=Acme Dev",
    "commit",
    "-q",
    "-m",
    "Initial import"
  ])

  path
end

reports_path =
  make_repo.("acme-reports", [
    {"README.md",
     "# acme-reports\n\nThe Reports page: a Flask API (`acme/reports`) and a React front end (`web/`).\n"},
    {".gitignore", ".canopy/\nnode_modules/\n__pycache__/\n"},
    {"acme/reports/__init__.py", ""},
    {"acme/reports/reports.py", reports_py},
    {"acme/reports/api.py", api_py},
    {"acme/reports/store.py", store_py},
    {"tests/test_reports.py", test_reports_py},
    {"web/src/components/DataTable.tsx", data_table_tsx},
    {"web/src/pages/ReportsPage.tsx", reports_page_tsx},
    {"web/src/api/reports.ts", reports_api_ts}
  ])

# @designer's three mockups, waiting where a designer would have drawn them
# (.canopy/ is ignored, so they never count as changes).
for key <- ~w(a b c) do
  dest = Path.join(reports_path, ".canopy/out/designs/csv-export-option-#{key}.png")
  File.mkdir_p!(Path.dirname(dest))
  File.cp!(Path.expand("../fixtures/reports-option-#{key}.png", __DIR__), dest)
end

if old = Repositories.get_by_path(Path.join([root, "tmp", "e2e-repo"])), do: Repo.delete!(old)

{:ok, reports_repo} = Repositories.create(%{name: "acme-reports", path: reports_path})

# -- Agents -----------------------------------------------------------------------

cast = ~w(project-manager designer frontend backend test reviewer researcher)

Repo.delete_all(from(a in Canopy.Agents.Agent, where: a.name not in ^cast))

{:ok, _} =
  Settings.put_default_model("opencode", %{model_provider: "opencode", model_id: "gpt-5-nano"})

{:ok, _} = Settings.put_default_model("claude_code", %{model_id: "sonnet"})

# The run's whole cast is on the fake Claude Code; each turn of the story is
# scripted in e2e/fake-claude/claude.mjs. @backend runs in default mode, so its
# first edit asks (the permission card); @frontend and @test accept edits.
set_claude = fn name, attrs ->
  {:ok, agent} =
    Agents.update(
      Agents.get_by_name(name),
      Map.merge(
        %{
          engine: "claude_code",
          model_provider: nil,
          permission_mode: "default",
          allowed_tools: "Read\nGrep\nGlob"
        },
        attrs
      )
    )

  agent
end

pm = set_claude.("project-manager", %{model_id: "haiku", effort: "low"})
designer = set_claude.("designer", %{model_id: "sonnet", effort: "medium"})

frontend =
  set_claude.("frontend", %{
    model_id: "sonnet",
    effort: "medium",
    permission_mode: "acceptEdits",
    allowed_tools: "Read\nGrep\nGlob\nBash(npm test:*)"
  })

backend =
  set_claude.("backend", %{
    model_id: "sonnet",
    effort: "medium",
    allowed_tools: "Read\nGrep\nGlob\nBash(pytest:*)"
  })

_ =
  set_claude.("test", %{
    model_id: "haiku",
    effort: "medium",
    permission_mode: "acceptEdits",
    allowed_tools: "Read\nGrep\nGlob\nBash(pytest:*)\nBash(npx playwright:*)"
  })

_ =
  set_claude.("reviewer", %{
    model_id: "opus",
    effort: "high",
    allowed_tools: "Read\nGrep\nGlob\nBash(git diff:*)"
  })

# One agent on OpenCode, so the Agents page shows both engines.
{:ok, researcher} =
  Agents.update(Agents.get_by_name("researcher"), %{model_provider: nil, model_id: nil})

learned = fn days -> now |> DateTime.to_date() |> Date.add(-days) |> Date.to_iso8601() end

# @frontend adds "Reports use the shared DataTable component" during the run.
{:ok, _} =
  Memory.put(frontend.id, """
  ## #{learned.(9)}
  - `web/` is React 19 + Vite; run `npm test` from `web/` before reporting.
  - Priya wants a screenshot of every UI change in the PR description.
  """)

{:ok, _} =
  Memory.put(backend.id, """
  ## #{learned.(6)}
  - acme-reports serves its API with Flask; report SQL lives in `acme/reports/store.py` and runs read-only.
  - Priya prefers small PRs: one behaviour change per PR, tests in the same change.
  """)

{:ok, _} =
  Memory.put(designer.id, """
  ## #{learned.(12)}
  - The web app's buttons and menus come from the shared `web/src/components` kit; mock new UI from it, not from scratch.
  """)

{:ok, _} =
  Memory.put(pm.id, """
  ## #{learned.(4)}
  - Priya signs off design choices herself; post the options and wait for her pick.
  """)

# -- Two quiet channels for the sidebar --------------------------------------------------

stamp = fn channel_id, t ->
  Repo.update_all(
    from(e in Event, where: e.channel_id == ^channel_id and e.inserted_at > ^t),
    set: [inserted_at: t, updated_at: t]
  )

  Repo.update_all(
    from(m in Message, where: m.channel_id == ^channel_id and m.inserted_at > ^t),
    set: [inserted_at: t, updated_at: t]
  )
end

{:ok, dashboard} =
  Channels.create(%{
    repository_id: reports_repo.id,
    name: "dashboard-load-time",
    topic: "The dashboard takes 4 s to load for large teams",
    owner_agent_id: frontend.id,
    agent_ids: [backend.id, researcher.id]
  })

{:ok, _} =
  Messages.post_user_message(
    dashboard.id,
    user.id,
    "The dashboard takes about 4 seconds to load for teams over 200 people. Can you find where the time goes?"
  )

stamp.(dashboard.id, before.(2, 100))

{:ok, members_post} =
  Messages.post_agent_message(
    dashboard.id,
    researcher.id,
    "Most of it is one request: `/api/teams/members` returns every member with their full activity history (`acme/teams/api.py:31`). The dashboard only uses the first 20. Paging it would cut the payload by about 90%."
  )

stamp.(dashboard.id, before.(2, 90))

# A short side conversation on that finding (the site's "Side conversations").
{:ok, _} =
  Messages.thread_reply(
    members_post.id,
    {:agent, frontend.id},
    "The member list scrolls, so paging is fine on my side. Do we still need the activity history at all on this page?"
  )

stamp.(dashboard.id, before.(2, 70))

{:ok, _} =
  Messages.thread_reply(
    members_post.id,
    {:agent, researcher.id},
    "Only the last-active date, for the sort. A `last_active_at` field covers it; the full history can stay on the member page."
  )

stamp.(dashboard.id, before.(2, 52))

{:ok, _} =
  Messages.thread_reply(
    members_post.id,
    {:user, user.id},
    "Good. Page it and send `last_active_at` only."
  )

stamp.(dashboard.id, before.(2, 31))

# The channel's schedules: a daily check, and a watch on failed CI. The watch's
# first check is an hour out, so a capture never asks GitHub about the fake repo.
{:ok, _} =
  Canopy.Schedules.create(%{
    channel_id: dashboard.id,
    agent_id: researcher.id,
    created_by_agent_id: researcher.id,
    instruction: "Post the dashboard's p95 load time for the last 24 hours and flag any change over 20%",
    when: "0 9 * * 1-5"
  })

{:ok, _} =
  Canopy.Schedules.create_watch(%{
    channel_id: dashboard.id,
    agent_id: frontend.id,
    created_by_agent_id: frontend.id,
    instruction: "Read the failed run's log; if the dashboard tests broke, fix them and post what failed",
    cron: "*/5 * * * *",
    next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
    check: %{"source" => "ci_failures", "repo" => "acme/acme-reports", "branch" => "main"},
    check_state: %{"etag" => nil, "failures" => 0, "last_error" => nil, "fired" => 0},
    playbook: nil
  })

stamp.(dashboard.id, before.(2, 31))

{:ok, onboarding} =
  Channels.create(%{
    repository_id: reports_repo.id,
    name: "onboarding-checklist",
    topic: "A first-week checklist for new workspace admins",
    owner_agent_id: designer.id,
    agent_ids: [frontend.id]
  })

{:ok, _} =
  Messages.post_user_message(
    onboarding.id,
    user.id,
    "New admins keep asking what to set up first. Sketch a short checklist card for their first week."
  )

stamp.(onboarding.id, days_ago.(5, 10))

{:ok, _} =
  Messages.post_agent_message(
    onboarding.id,
    designer.id,
    "Five items, in the order admins hit them: invite the team, connect SSO, pick report defaults, set up a weekly digest, and turn on audit logs. I'll put two layouts up tomorrow."
  )

stamp.(onboarding.id, days_ago.(5, 10))

# read, so the sidebar shows no unread dots
for channel <- [dashboard, onboarding], do: Canopy.Unread.mark_read(channel.id, user)

IO.puts(
  "Reports seed: #{length(cast)} agents, acme-reports at #{reports_path}; the story's run starts in the browser."
)
