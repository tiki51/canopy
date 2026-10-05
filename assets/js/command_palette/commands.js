// The command palette's `>` commands: pages, "new" screens, the theme, and the
// open channel's own actions. Each has a `when(ctx)` so it is listed only
// where it can run, and an `action` the hook carries out:
//
//   {navigate: path}              live navigation
//   {push: event, payload}        an event for the page (the channel's handlers,
//                                 or Nav's release_hold on any page)
//   {dmPicker: true}              opens the "new direct message" modal
//   {theme: "system"|"light"|"dark"}
//   {notify: true|false}          the desktop notifications master switch
//
// `ctx`: {path, hold, channel: {id, kind, archived} | null, repoId,
// repos: [{id, name}], playbooks: [{id, name}], notify: "on" | "off" |
// "blocked" | "unsupported" | null}. No DOM here.

const PAGES = [
  ["search", "Search", "/search", "find messages turns files"],
  ["repositories", "Repositories", "/repositories", "folder repos git"],
  ["agents", "Agents", "/agents", "people bots"],
  ["teams", "Teams", "/teams", "groups"],
  ["playbooks", "Playbooks", "/playbooks", "workflows runs"],
  ["threads", "Threads", "/threads", "replies inbox"],
  ["files", "Files", "/files", "documents library uploads"],
  ["costs", "Costs", "/costs", "spend money budget"],
  ["settings", "Settings", "/settings", "preferences appearance engines"],
]

const inChannel = ctx => Boolean(ctx.channel) && !ctx.channel.archived
const inGroupChannel = ctx => inChannel(ctx) && ctx.channel.kind !== "dm"

const STATIC = [
  ...PAGES.map(([id, label, path, keywords]) => ({
    id: `go-${id}`,
    label: `Go to ${label}`,
    keywords: keywords.split(" "),
    when: ctx => ctx.path !== path,
    action: {navigate: path},
  })),
  {id: "new-channel", label: "New channel", keywords: ["create"], action: {navigate: "/channels/new"}},
  {id: "new-dm", label: "New direct message…", keywords: ["create", "dm", "message"], action: {dmPicker: true}},
  {id: "new-agent", label: "New agent", keywords: ["create"], action: {navigate: "/agents/new"}},
  {id: "import-agents", label: "Import agents…", keywords: ["template", "upload", "bundle", "team"], when: ctx => ctx.path !== "/agents/import", action: {navigate: "/agents/import"}},
  {id: "agent-gallery", label: "Agent gallery", keywords: ["templates", "starter", "add"], when: ctx => ctx.path !== "/agents/gallery", action: {navigate: "/agents/gallery"}},
  {id: "new-team", label: "New team", keywords: ["create"], action: {navigate: "/teams/new"}},
  {id: "new-playbook", label: "New playbook", keywords: ["create", "workflow"], action: {navigate: "/playbooks/new"}},
  {id: "theme-system", label: "Theme: System", keywords: ["appearance", "mode", "auto"], action: {theme: "system"}},
  {id: "theme-light", label: "Theme: Light", keywords: ["appearance", "mode"], action: {theme: "light"}},
  {id: "theme-dark", label: "Theme: Dark", keywords: ["appearance", "mode", "night"], action: {theme: "dark"}},
  // the wording follows the switch in this browser; blocked still offers "on",
  // which explains itself in Settings
  {
    id: "notify-off",
    label: "Turn desktop notifications off",
    keywords: ["notifications", "alerts", "mute", "quiet", "disable"],
    when: ctx => ctx.notify === "on",
    action: {notify: false},
  },
  {
    id: "notify-on",
    label: "Turn desktop notifications on",
    keywords: ["notifications", "alerts", "unmute", "enable"],
    when: ctx => ctx.notify === "off" || ctx.notify === "blocked",
    action: {notify: true},
  },
  {
    id: "release-hold",
    label: "Release hold",
    keywords: ["billing", "resume", "unpause"],
    when: ctx => ctx.hold,
    action: {push: "release_hold"},
  },
  // the open channel's header buttons, and its Details panel
  {
    id: "details-show",
    label: "Show channel details",
    keywords: ["panel", "info", "sidebar", "members", "locks"],
    when: ctx => Boolean(ctx.channel),
    action: {push: "toggle_details", payload: {open: true}},
  },
  {
    id: "details-hide",
    label: "Hide channel details",
    keywords: ["panel", "info", "sidebar", "close"],
    when: ctx => Boolean(ctx.channel),
    action: {push: "toggle_details", payload: {open: false}},
  },
  {
    id: "stop-all",
    label: "Stop all agents here",
    keywords: ["abort", "halt", "stop"],
    when: inChannel,
    action: {push: "stop_all"},
  },
  {id: "members", label: "Channel: members", keywords: ["add", "remove", "agents"], when: inGroupChannel, action: {push: "toggle_members"}},
  {id: "task", label: "Channel: task", keywords: ["goal", "edit"], when: inChannel, action: {push: "toggle_task_form"}},
  {id: "brief", label: "Channel: brief", keywords: ["context", "edit", "instructions"], when: inChannel, action: {push: "toggle_brief_form"}},
  {id: "playbook", label: "Channel: run a playbook", keywords: ["start", "workflow"], when: inGroupChannel, action: {push: "toggle_playbook"}},
  {id: "schedules", label: "Channel: scheduled tasks", keywords: ["later", "cron", "schedule"], when: inChannel, action: {push: "toggle_schedules"}},
  {id: "budget", label: "Channel: budget", keywords: ["spend", "limit", "cost"], when: inChannel, action: {push: "toggle_budget"}},
  {
    id: "activity",
    label: "Channel: show or hide routine activity",
    keywords: ["compact", "timeline", "toggle"],
    when: ctx => Boolean(ctx.channel),
    action: {push: "toggle_activity"},
  },
  {id: "changes", label: "Channel: show changes", keywords: ["diff", "git", "files"], when: ctx => Boolean(ctx.channel), action: {push: "open_changes"}},
  {
    id: "library",
    label: "Channel: attach from the library",
    keywords: ["files", "documents", "share"],
    when: inChannel,
    action: {push: "open_library", payload: {target: "main"}},
  },
]

// Every command that can run here, in catalog order; one "New channel in
// <repo>" per repository (the current one first) and one "Start playbook"
// per enabled playbook.
export function commands(ctx) {
  const listed = STATIC.filter(command => !command.when || command.when(ctx))

  const repos = [...(ctx.repos || [])].sort((a, b) => (b.id === ctx.repoId) - (a.id === ctx.repoId))
  const perRepo = repos.map(repo => ({
    id: `new-channel-in-${repo.id}`,
    label: `New channel in ${repo.name}`,
    keywords: ["create"],
    action: {navigate: `/channels/new?repository_id=${encodeURIComponent(repo.id)}`},
  }))

  const playbooks = (ctx.playbooks || []).map(playbook => ({
    id: `start-playbook-${playbook.id}`,
    label: `Start playbook: ${playbook.name}`,
    keywords: ["run", "workflow"],
    action: {navigate: `/playbooks/${encodeURIComponent(playbook.id)}/start`},
  }))

  const at = listed.findIndex(command => command.id === "new-dm")
  return [...listed.slice(0, at), ...perRepo, ...listed.slice(at), ...playbooks]
}
