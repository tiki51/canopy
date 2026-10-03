// The command palette (⌘K on a Mac, Ctrl+K elsewhere; the sidebar's "Jump to…").
//
// The server renders a closed <dialog> inside #cmdk, a phx-update="ignore"
// container whose data attributes LiveView keeps current (see
// CanopyWeb.CommandPalette); this hook owns everything inside the dialog. The
// data is read on open and on every keystroke, each value parsed once per
// string: an ignored container's hook gets no updated() call to wait for.
//
// Keys meant for the palette stop here: Escape, Enter and the arrows go no
// further than the dialog, so the window-level Escape handlers (the library,
// the changes modal) and the side panel's never see them. The dialog is modal
// (showModal), so nothing outside it takes keys while it is open.
//
// Recents (localStorage "canopy:cmdk-recent", most recent first) hold the
// channels, DMs and agents you visit as well as what you pick here.
import {rank, tokens} from "../command_palette/match"
import {commands as pageCommands} from "../command_palette/commands"

const RECENT_KEY = "canopy:cmdk-recent"
const RECENT_MAX = 20
const DRAFT_PREFIX = "canopy:cmdk-draft:"
const MODES = {
  "#": {chip: "# channels", placeholder: "Jump to a channel…"},
  "@": {chip: "@ agents", placeholder: "Jump to an agent, team or DM…"},
  ">": {chip: "> commands", placeholder: "Run a command…"},
  "/": {chip: "/ slash", placeholder: "Start a slash command…"},
}
const PLACEHOLDER = "Jump to a channel, agent, file or command…"
const LIMITS = {channels: 5, dms: 5, agents: 5, repos: 3, files: 5, commands: 6}
const MODE_LIMIT = 30

const ROW_CLASS =
  "group mx-1.5 flex cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-base-content/85 " +
  "aria-selected:bg-primary/10 aria-selected:text-primary dark:aria-selected:bg-primary/15"

const CommandPalette = {
  mounted() {
    this.dialog = this.el.querySelector("#cmdk-dialog")
    this.input = this.el.querySelector("#cmdk-input")
    this.list = this.el.querySelector("#cmdk-list")
    this.chip = this.el.querySelector("#cmdk-chip")
    this.status = this.el.querySelector("#cmdk-status")
    this.cache = {}
    this.mode = null
    this.step = null
    this.rows = []
    this.active = 0
    this.files = []
    this.fileSeq = 0

    this.el.addEventListener("cmdk:toggle", () => (this.dialog.open ? this.close() : this.open()))
    this.input.addEventListener("input", () => this.onInput())
    this.dialog.addEventListener("keydown", e => this.onKeydown(e))
    // Escape (and other close requests) go through close(), as the confirm dialog's do
    this.dialog.addEventListener("cancel", e => {
      e.preventDefault()
      this.close()
    })
    this.dialog.addEventListener("click", e => {
      if (e.target === this.dialog) this.close()
    })
    // the caret stays in the input while rows are clicked
    this.list.addEventListener("mousedown", e => e.preventDefault())
    this.list.addEventListener("click", e => {
      const row = e.target.closest("[role=option]")
      if (!row) return
      this.active = Number(row.dataset.index)
      this.choose(e.shiftKey)
    })
    this.list.addEventListener("mousemove", e => {
      const row = e.target.closest("[role=option]")
      if (row && Number(row.dataset.index) !== this.active) this.setActive(Number(row.dataset.index), false)
    })

    this.rememberVisit()
  },

  destroyed() {
    clearTimeout(this.fileTimer)
    clearTimeout(this.statusTimer)
    if (this.dialog && this.dialog.open) this.dialog.close()
  },

  // -- Data ------------------------------------------------------------------

  read(name, fallback) {
    const raw = this.el.dataset[name] || ""
    const hit = this.cache[name]
    if (hit && hit.raw === raw) return hit.value
    let value = fallback
    try {
      if (raw) value = JSON.parse(raw)
    } catch (_e) {
      value = fallback
    }
    this.cache[name] = {raw, value}
    return value
  },

  items() { return this.read("items", []) },
  badges() { return this.read("badges", {}) },
  context() { return this.read("context", {}) },
  slashCommands() { return this.read("commands", []) },

  // The searchable rows for data-items, rebuilt only when it changes.
  entries() {
    const raw = this.el.dataset.items || ""
    if (this.entriesRaw !== raw) {
      this.entriesRaw = raw
      this.entriesList = this.items().map(toEntry).filter(Boolean)
    }
    return this.entriesList
  },

  currentChannel() {
    const id = this.context().channel_id
    if (!id) return null
    const item = this.items().find(i => (i.t === "channel" || i.t === "dm") && i.id === id)
    return item ? {id, kind: item.t, archived: item.archived} : null
  },

  commandContext() {
    const ctx = this.context()
    const items = this.items()
    return {
      path: ctx.path,
      hold: ctx.hold,
      channel: this.currentChannel(),
      repoId: ctx.repo_id,
      repos: items.filter(i => i.t === "repo"),
      playbooks: items.filter(i => i.t === "playbook"),
      notify: window.canopyNotifier ? window.canopyNotifier.status() : null,
    }
  },

  commandEntries() {
    return pageCommands(this.commandContext()).map(command => ({
      key: `cmd:${command.id}`,
      kind: "command",
      label: command.label,
      fields: [command.label, ...(command.keywords || [])],
      command,
    }))
  },

  // -- Recents ---------------------------------------------------------------

  loadRecents() {
    try {
      const list = JSON.parse(localStorage.getItem(RECENT_KEY) || "[]")
      return Array.isArray(list) ? list.filter(r => r && typeof r.t === "string" && typeof r.id === "string") : []
    } catch (_e) {
      return []
    }
  },

  saveRecents(list) {
    try {
      localStorage.setItem(RECENT_KEY, JSON.stringify(list.slice(0, RECENT_MAX)))
    } catch (_e) {
      // private mode or storage full: recents are a convenience
    }
  },

  remember(t, id) {
    const list = this.loadRecents().filter(r => !(r.t === t && r.id === id))
    list.unshift({t, id})
    this.saveRecents(list)
  },

  // The hook mounts on every navigation, so a visit to a channel, DM or
  // agent page counts as recent too.
  rememberVisit() {
    const ctx = this.context()
    const items = this.items()
    const agent = ((ctx.path || "").match(/^\/agents\/([^/]+)$/) || [])[1]
    const id = ctx.channel_id || agent
    const item = id && items.find(i => i.id === id && ["channel", "dm", "agent"].includes(i.t))
    if (item) this.remember(item.t, item.id)
  },

  recentKeys() {
    return this.loadRecents().map(r => `${r.t}:${r.id}`)
  },

  // -- Open and close --------------------------------------------------------

  open() {
    if (this.dialog.open) return
    // the mobile drawer slides away under the dialog
    const drawer = document.getElementById("app-drawer")
    if (drawer) drawer.checked = false
    this.returnTo = document.activeElement
    this.mode = null
    this.step = null
    this.files = []
    this.fileSeq++
    this.input.value = ""
    this.active = 0
    this.dialog.showModal()
    this.input.focus()
    this.render()
  },

  close() {
    clearTimeout(this.fileTimer)
    if (!this.dialog.open) return
    this.dialog.close()
    const back = this.returnTo
    this.returnTo = null
    if (back && back !== document.body && back.isConnected && typeof back.focus === "function") back.focus()
  },

  // -- Keys ------------------------------------------------------------------

  onInput() {
    const value = this.input.value
    if (!this.mode && !this.step && value !== "" && MODES[value[0]]) {
      this.mode = value[0]
      this.input.value = value.slice(1)
    }
    this.active = 0
    this.render()
    this.requestFiles()
  },

  onKeydown(e) {
    if (e.isComposing) return
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      e.stopPropagation()
      if (this.rows.length === 0) return
      const step = e.key === "ArrowDown" ? 1 : -1
      this.setActive((this.active + step + this.rows.length) % this.rows.length, true)
    } else if (e.key === "Enter") {
      e.preventDefault()
      e.stopPropagation()
      this.choose(e.shiftKey)
    } else if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      this.close()
    } else if (e.key === "Backspace" && this.input.value === "" && (this.step || this.mode)) {
      // Backspace on an empty query steps back: out of the channel step, then out of the mode
      e.preventDefault()
      if (this.step) {
        this.input.value = this.step.typed
        this.step = null
      } else {
        this.mode = null
      }
      this.active = 0
      this.render()
    }
  },

  choose(alt) {
    const query = this.input.value.trim()
    if (this.rows.length === 0 && alt && !this.mode && !this.step && query.length >= 2) {
      this.row(searchEntry(query)).enter()
      return
    }
    const row = this.rows[this.active]
    const action = row && (alt ? row.alt : row.enter)
    if (action) action()
  },

  // -- Results ---------------------------------------------------------------

  groups() {
    const query = this.input.value
    if (this.step) return [{name: `Run /${this.step.command.name} in…`, rows: this.stepRows(query)}]
    if (this.mode === "/") return [{name: "Slash commands", rows: this.slashRows(query)}]

    const opts = {recents: this.recentKeys(), badges: this.badges(), context: this.context()}
    if (!this.mode && tokens(query).length === 0) return this.emptyGroups(opts)

    const entries = this.entries()
    const of = (...kinds) => entries.filter(e => kinds.includes(e.kind))
    const specs = {
      none: [
        ["Channels", of("channel", "dm"), LIMITS.channels],
        ["Agents", of("agent", "team"), LIMITS.agents],
        ["Repositories", of("repo"), LIMITS.repos],
        ["Files", this.files.map(fileEntry), LIMITS.files],
        ["Commands", this.commandEntries(), LIMITS.commands],
      ],
      "#": [["Channels", of("channel"), MODE_LIMIT]],
      "@": [
        ["Agents", of("agent", "team"), MODE_LIMIT],
        ["Direct messages", of("dm"), LIMITS.dms],
      ],
      ">": [["Commands", this.commandEntries(), MODE_LIMIT]],
    }[this.mode || "none"]

    const groups = specs
      .map(([name, list, limit]) => {
        const ranked = rank(list, query, opts)
        return {name, best: ranked.length ? ranked[0].score : -Infinity, rows: ranked.slice(0, limit).map(r => this.row(r.item))}
      })
      .filter(group => group.rows.length > 0)
      .sort((a, b) => b.best - a.best)

    // the Search page looks inside messages, turns and files; it goes last,
    // so Enter keeps opening the best name match (with none, ⇧↵ searches)
    if (!this.mode && groups.length > 0 && query.trim().length >= 2) {
      groups.push({name: "Search", rows: [this.row(searchEntry(query.trim()))]})
    }
    return groups
  },

  // Nothing typed: where you have been, what needs you, and the pages.
  emptyGroups(opts) {
    const ctx = this.context()
    const entries = this.entries()
    const commands = this.commandEntries()
    const byKey = new Map(entries.concat(commands).map(e => [e.key, e]))
    const here = new Set([ctx.channel_id && `channel:${ctx.channel_id}`, ctx.channel_id && `dm:${ctx.channel_id}`])
    const agentHere = ((ctx.path || "").match(/^\/agents\/([^/]+)$/) || [])[1]
    if (agentHere) here.add(`agent:${agentHere}`)

    // ids that no longer exist are pruned as they are read
    const known = this.loadRecents().filter(r => byKey.has(`${r.t}:${r.id}`) || r.t === "cmd")
    if (known.length !== this.loadRecents().length) this.saveRecents(known)
    const recent = opts.recents.filter(key => byKey.has(key) && !here.has(key)).slice(0, 6).map(key => byKey.get(key))

    const badges = opts.badges
    const needs = entries
      .filter(e => e.channelId && !e.archived && !here.has(e.key) && badges[e.channelId])
      .filter(e => badges[e.channelId][2] > 0 || badges[e.channelId][1] > 0)
      .sort((a, b) => badges[b.channelId][2] - badges[a.channelId][2] || badges[b.channelId][1] - badges[a.channelId][1])
      .slice(0, 5)

    const pages = commands.filter(e => e.command.id.startsWith("go-"))

    return [
      {name: "Recent", rows: recent.map(e => this.row(e))},
      {name: "Needs you", rows: needs.map(e => this.row(e))},
      {name: "Go to", rows: pages.map(e => this.row(e))},
    ].filter(group => group.rows.length > 0)
  },

  // `/` mode: the first word picks the command; the rest rides along into
  // the composer. Commands that can't run here are left out.
  slashRows(query) {
    const trimmed = query.trim()
    const first = trimmed.split(/\s+/)[0] || ""
    const args = trimmed.slice(first.length).trim()
    const channel = this.currentChannel()
    const list = this.slashCommands().filter(
      command => !channel || (!channel.archived && (channel.kind !== "dm" || command.dm)),
    )
    const entries = list.map(command => ({
      key: `slash:${command.name}`,
      kind: "slash",
      fields: [command.name, ...command.aliases],
      command,
      args,
    }))
    return rank(entries, first).map(r => this.row(r.item))
  },

  // Outside a channel, a slash command first asks where to run.
  stepRows(query) {
    const command = this.step.command
    const entries = this.entries().filter(
      e => !e.archived && (e.kind === "channel" || (e.kind === "dm" && command.dm)),
    )
    const opts = {recents: this.recentKeys(), badges: this.badges(), context: this.context()}
    return rank(entries, query, opts)
      .slice(0, MODE_LIMIT)
      .map(r => ({...this.row(r.item), enter: () => this.runIn(r.item), alt: null, hints: ["↵ choose"]}))
  },

  // What a row shows and does on Enter and Shift+Enter.
  row(entry) {
    const ctx = this.context()
    const go = path => () => {
      this.remember(entry.kind, entry.id)
      this.close()
      this.js().navigate(path)
    }

    switch (entry.kind) {
      case "channel":
      case "dm":
        return {...entry, enter: go(`/channels/${entry.id}`), hints: ["↵ open"]}
      case "agent": {
        const dm = `/dm/${encodeURIComponent(entry.id)}` + (ctx.repo_id ? `?repository=${encodeURIComponent(ctx.repo_id)}` : "")
        const message = () => {
          this.remember("agent", entry.id)
          this.close()
          window.location.assign(dm)
        }
        return {...entry, enter: go(`/agents/${entry.id}`), alt: message, hints: ["↵ open", "⇧↵ message"]}
      }
      case "team":
        return {...entry, enter: go(`/teams/${entry.id}/edit`), hints: ["↵ open"]}
      case "repo":
        return {
          ...entry,
          enter: go(`/repositories/${entry.id}`),
          alt: go(`/channels/new?repository_id=${encodeURIComponent(entry.id)}`),
          hints: ["↵ open", "⇧↵ new channel"],
        }
      case "file": {
        const open = () => {
          this.close()
          window.open(entry.file.url, "_blank", "noopener")
        }
        const channel = this.currentChannel()
        const attach = () => {
          this.close()
          if (channel && !channel.archived) {
            this.js().patch(`/channels/${channel.id}?attach=${encodeURIComponent(entry.id)}`)
          } else {
            this.js().navigate(`/files?q=${encodeURIComponent(entry.file.filename)}`)
          }
        }
        return {...entry, enter: open, alt: attach, hints: ["↵ open", channel && !channel.archived ? "⇧↵ attach" : "⇧↵ in Files"]}
      }
      case "command":
        return {...entry, enter: () => this.run(entry.command), hints: ["↵ run"]}
      case "search":
        return {...entry, enter: go(`/search?q=${encodeURIComponent(entry.query)}`), hints: ["↵ search"]}
      case "slash": {
        const here = this.currentChannel()
        const hint = !here ? "↵ choose a channel" : entry.command.prefill ? "↵ write" : "↵ run"
        return {...entry, enter: () => this.slash(entry.command, entry.args), hints: [hint]}
      }
    }
    return entry
  },

  run(command) {
    this.remember("cmd", command.id)
    this.close()
    const action = command.action
    if (action.navigate) this.js().navigate(action.navigate)
    else if (action.push) this.pushEvent(action.push, action.payload || {}, () => {})
    else if (action.dmPicker) this.pushEventTo("#dm-picker-component", "open_picker", {}, () => {})
    else if (action.theme) this.setTheme(action.theme)
    else if ("notify" in action) this.setNotify(action.notify)
  },

  // The desktop notifications switch (../notify.js). Choosing "on" is the
  // click the browser's permission prompt needs; Nav confirms with a flash,
  // and a browser that refuses sends the user to Settings, which explains.
  setNotify(on) {
    const notifier = window.canopyNotifier
    if (!notifier) return
    notifier.setEnabled(on).then(ok => {
      if (ok) this.pushEvent("cmdk:notify", {on}, () => {})
      else this.js().navigate("/settings")
    })
  },

  // The palette never posts: a slash command is written into the composer,
  // so there is one executor and one error path. /stop runs at once, as the
  // Stop button does.
  slash(command, args) {
    const text = args ? `/${command.name} ${args}` : command.prefill || `/${command.name}`
    if (this.currentChannel()) {
      this.close()
      if (command.prefill) this.prefill(text)
      else this.pushEvent("stop_all", {}, () => {})
      return
    }
    this.step = {command, text, typed: this.input.value}
    this.input.value = ""
    this.active = 0
    this.render()
  },

  // The channel step's choice: a draft waits in sessionStorage for that
  // channel's composer (Composer hook); /stop asks Nav and stays here.
  runIn(entry) {
    const {command, text} = this.step
    this.close()
    if (!command.prefill) {
      this.pushEvent("cmdk:stop", {channel_id: entry.id}, () => {})
      return
    }
    try {
      sessionStorage.setItem(DRAFT_PREFIX + entry.id, text)
    } catch (_e) {
      // without storage the channel still opens, the composer just stays empty
    }
    this.remember(entry.kind, entry.id)
    this.js().navigate(`/channels/${entry.id}`)
  },

  prefill(text) {
    const input = document.getElementById("composer-input")
    if (!input) return
    input.dispatchEvent(new CustomEvent("cmdk:prefill", {detail: {text}}))
    // below lg an open side panel hides the channel's composer
    if (input.offsetParent === null) this.pushEvent("close_panel", {}, () => requestAnimationFrame(() => input.focus()))
  },

  // The root layout's theme script reads data-phx-theme off the event's target.
  setTheme(theme) {
    const target = document.createElement("span")
    target.hidden = true
    target.dataset.phxTheme = theme
    this.el.appendChild(target)
    target.dispatchEvent(new CustomEvent("phx:set-theme", {bubbles: true}))
    target.remove()
  },

  // Files are not in data-items: there can be hundreds. Nav searches their
  // names once the query has two characters; a reply a later keystroke
  // overtook is dropped.
  requestFiles() {
    clearTimeout(this.fileTimer)
    const seq = ++this.fileSeq
    const q = this.input.value.trim()
    if (this.step || this.mode || q.length < 2) {
      if (this.files.length > 0) {
        this.files = []
        this.render(true)
      }
      return
    }
    this.fileTimer = setTimeout(() => {
      this.pushEvent("cmdk:files", {q, seq}, reply => {
        if (!reply || reply.seq !== seq || !this.dialog.open) return
        this.files = reply.files || []
        this.render(true)
      })
    }, 120)
  },

  // -- Rendering -------------------------------------------------------------

  // `keep`: a refresh under the same query (files arrived) keeps the row the
  // reader moved to; the top row stays the top row.
  render(keep = false) {
    const activeKey = keep && this.active > 0 && this.rows[this.active] ? this.rows[this.active].key : null
    const groups = this.groups()
    this.rows = []
    const nodes = groups.map((group, g) => {
      const wrap = document.createElement("div")
      wrap.setAttribute("role", "group")
      wrap.setAttribute("aria-labelledby", `cmdk-group-${g}`)
      const heading = document.createElement("div")
      heading.id = `cmdk-group-${g}`
      heading.className = "px-3 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-wider text-base-content/50"
      heading.textContent = group.name
      wrap.appendChild(heading)
      group.rows.forEach(row => {
        wrap.appendChild(this.renderRow(row, this.rows.length))
        this.rows.push(row)
      })
      return wrap
    })
    if (this.rows.length === 0) {
      const empty = document.createElement("p")
      empty.id = "cmdk-empty"
      empty.className = "px-4 py-6 text-center text-sm text-base-content/50"
      empty.textContent = this.emptyText()
      nodes.push(empty)
    }
    this.list.replaceChildren(...nodes)

    const kept = activeKey ? this.rows.findIndex(row => row.key === activeKey) : -1
    this.active = kept >= 0 ? kept : Math.min(this.active, Math.max(this.rows.length - 1, 0))
    this.setActive(this.active, false)
    this.renderChip()
    this.announce()
  },

  renderRow(row, index) {
    const el = document.createElement("div")
    el.id = `cmdk-opt-${index}`
    el.dataset.index = index
    el.dataset.key = row.key
    el.setAttribute("role", "option")
    el.setAttribute("aria-selected", "false")
    el.className = ROW_CLASS

    const glyph = document.createElement("span")
    glyph.setAttribute("aria-hidden", "true")
    glyph.className = "flex w-4 shrink-0 justify-center text-base-content/50 group-aria-selected:text-primary/70"
    const icon = ICONS[row.kind]
    if (icon) {
      const span = document.createElement("span")
      span.className = `${icon} size-4`
      glyph.appendChild(span)
    } else {
      glyph.textContent = row.kind === "channel" ? "#" : row.kind === "slash" ? "/" : "@"
    }
    el.appendChild(glyph)

    const label = document.createElement("span")
    label.className = "min-w-0 shrink truncate font-medium"
    label.textContent = rowLabel(row)
    el.appendChild(label)

    const sub = rowSub(row)
    if (sub) {
      const span = document.createElement("span")
      span.className = "min-w-0 flex-1 truncate text-xs text-base-content/50"
      span.textContent = sub
      el.appendChild(span)
    } else {
      el.appendChild(Object.assign(document.createElement("span"), {className: "flex-1"}))
    }

    if (row.archived) el.appendChild(tag("archived", "rounded bg-base-300 px-1 text-[10px] text-base-content/60"))
    const badge = row.channelId && this.badges()[row.channelId]
    if (badge && badge[2] > 0) {
      el.appendChild(tag(String(badge[2]), "rounded-full bg-info px-1.5 text-[10px] font-bold text-info-content", "waiting on you"))
    } else if (badge && badge[1] > 0) {
      el.appendChild(tag(String(badge[1]), "rounded-full bg-primary px-1.5 text-[10px] font-bold text-primary-content", "mentions"))
    } else if (badge && badge[0] > 0) {
      el.appendChild(tag("", "size-2 rounded-full bg-secondary", "unread"))
    }

    if (row.hints && row.hints.length) {
      const hints = document.createElement("span")
      hints.className = "hidden shrink-0 gap-2 text-[11px] text-primary/70 group-aria-selected:flex pointer-coarse:hidden!"
      hints.textContent = row.hints.join("  ")
      el.appendChild(hints)
    }
    return el
  },

  setActive(index, scroll) {
    this.active = index
    let current = null
    this.list.querySelectorAll("[role=option]").forEach(el => {
      const on = Number(el.dataset.index) === index
      el.setAttribute("aria-selected", String(on))
      if (on) current = el
    })
    if (current) {
      this.input.setAttribute("aria-activedescendant", current.id)
      if (scroll) current.scrollIntoView({block: "nearest"})
    } else {
      this.input.removeAttribute("aria-activedescendant")
    }
  },

  renderChip() {
    const text = this.step ? `/${this.step.command.name} ›` : this.mode ? MODES[this.mode].chip : ""
    this.chip.textContent = text
    this.chip.hidden = text === ""
    this.input.placeholder = this.step
      ? "Choose a channel…"
      : this.mode
        ? MODES[this.mode].placeholder
        : PLACEHOLDER
  },

  emptyText() {
    const channel = this.currentChannel()
    if (this.mode === "/" && channel && channel.archived) return "Slash commands can't run in an archived channel."
    if (!this.mode && !this.step && this.input.value.trim().length >= 2) return "No matches. ⇧↵ searches messages, turns and files."
    return "No matches."
  },

  // A screen reader hears the count (and the step), once typing settles.
  announce() {
    clearTimeout(this.statusTimer)
    const count = this.rows.length
    const results = `${count} ${count === 1 ? "result" : "results"}`
    const text = this.step ? `Choose a channel for /${this.step.command.name}. ${results}` : results
    this.statusTimer = setTimeout(() => {
      this.status.textContent = text
    }, 300)
  },
}

const ICONS = {
  dm: "hero-chat-bubble-left-right-mini",
  team: "hero-user-group-mini",
  repo: "hero-folder-mini",
  file: "hero-document-mini",
  command: "hero-command-line-mini",
  search: "hero-magnifying-glass-mini",
}

function toEntry(item) {
  switch (item.t) {
    case "channel":
      return {
        key: `channel:${item.id}`,
        kind: "channel",
        id: item.id,
        name: item.name,
        repo: item.repo,
        archived: item.archived,
        channelId: item.id,
        repoId: item.repo_id,
        fields: [item.name, item.repo, `${item.repo}/${item.name}`],
      }
    case "dm":
      return {
        key: `dm:${item.id}`,
        kind: "dm",
        id: item.id,
        name: item.label,
        repo: item.repo,
        archived: item.archived,
        channelId: item.id,
        repoId: item.repo_id,
        fields: [item.label, item.repo],
      }
    case "agent":
      return {
        key: `agent:${item.id}`,
        kind: "agent",
        id: item.id,
        name: item.name,
        role: item.role,
        fields: [item.name, item.role, item.group],
      }
    case "team":
      return {key: `team:${item.id}`, kind: "team", id: item.id, name: item.name, fields: [item.name]}
    case "repo":
      return {key: `repo:${item.id}`, kind: "repo", id: item.id, name: item.name, repoId: item.id, fields: [item.name]}
  }
  return null
}

function searchEntry(query) {
  return {key: "search", kind: "search", query, label: `Search everywhere for “${query}”`, fields: [query]}
}

function fileEntry(file) {
  return {key: `file:${file.id}`, kind: "file", id: file.id, file, fields: [file.filename]}
}

function rowLabel(row) {
  switch (row.kind) {
    case "agent":
    case "team":
      return `@${row.name}`
    case "file":
      return row.file.filename
    case "command":
    case "search":
      return row.label
    case "slash":
      return row.command.usage
    default:
      return row.name
  }
}

function rowSub(row) {
  switch (row.kind) {
    case "channel":
    case "dm":
      return row.repo
    case "agent":
      return row.role
    case "team":
      return "team"
    case "repo":
      return "repository"
    case "file":
      return [row.file.kind, row.file.size_label].filter(Boolean).join(" · ")
    case "slash":
      return row.command.summary
  }
  return null
}

function tag(text, className, title) {
  const span = document.createElement("span")
  span.className = `flex h-4 min-w-2 shrink-0 items-center justify-center leading-none ${className}`
  span.textContent = text
  if (title) span.title = title
  return span
}

export default CommandPalette
