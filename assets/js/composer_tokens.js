// What the composer highlights in a draft: the pure part, with no DOM access,
// so the e2e suite can import it directly. `tokenize(text, ctx)` returns
// `[{kind, text}]`; joining every token's text gives back the input.
//
//   mention   @agent who is in the channel, or @team with a member here: wakes
//   outsider  @agent not in the channel, or @team with nobody here: wakes nobody
//   channel   #name of a known channel
//   command   the leading /command (invalid instead in a thread, where the
//             server rejects it)
//   plain     everything else, including unknown @words
//
// The rules follow the server, which stays the source of truth:
// Canopy.Messages @mention_regex and Canopy.Messages.CodeMask (what wakes),
// CanopyWeb.Markdown @channel_regex, and Canopy.Runtime.Commands.parse/1.
// test/support/composer_token_cases.json holds the cases both sides must agree
// on (composer_token_parity_test.exs and e2e/tests/composer-tokens.spec.ts).
//
// No regex lookbehind here: an older Safari can't parse it, and a SyntaxError
// would take down the whole app.js. The character before a match is checked
// by hand instead.
//
// ctx: {members: Set, agents: Set, teams: Map(name => [member names]),
//       channels: Set, commands: Set, thread: boolean}, names lowercase.

const NAME = /[a-z0-9][a-z0-9_-]*/iy
const BEFORE_MENTION = /[A-Za-z0-9_@]/
const BEFORE_CHANNEL = /[A-Za-z0-9_#&/]/
const COMMAND = /^\s*\/(\w+)(?=[ \t\n\r\f\v]|$)/
const TARGET = /^[ \t\n\r\f\v]*(@?[A-Za-z0-9][\w-]*)/
const OPEN_FENCE = /^[ \t]*(`{3,}|~{3,})(.*)$/

export function tokenize(text, ctx) {
  const marks = []
  const command = COMMAND.exec(text)
  const name = command && command[1].toLowerCase()

  if (!command || !ctx.commands.has(name)) {
    scan(maskCode(text), 0, ctx, marks)
    return build(text, marks)
  }

  const cmdStart = command[0].length - command[1].length - 1
  const cmdEnd = command[0].length
  marks.push([cmdStart, cmdEnd, ctx.thread ? "invalid" : "command"])
  // /stop takes nothing; /playbook takes a playbook's name, never an agent
  if (ctx.thread || name === "stop" || name === "playbook") return build(text, marks)

  const target = TARGET.exec(text.slice(cmdEnd))
  if (!target) return build(text, marks)

  const targetEnd = cmdEnd + target[0].length
  const targetName = target[1].replace(/^@/, "").toLowerCase()
  const kind = commandTarget(name, targetName, ctx)
  if (kind) marks.push([targetEnd - target[1].length, targetEnd, kind])

  // `/i @x note` posts "@x note" as a normal message, so the note's mentions
  // wake as usual (an unknown target posts nothing); /handoff and /delegate
  // post theirs with no mentions.
  if (kind && (name === "i" || name === "invite")) {
    const noteStart = targetEnd + text.slice(targetEnd).match(/^[ \t\n\r\f\v]*/)[0].length
    const note = text.slice(noteStart)
    scan(maskCode("x " + note).slice(2), noteStart, ctx, marks)
  }
  return build(text, marks)
}

function commandTarget(command, name, ctx) {
  if (command === "i" || command === "invite") {
    return ctx.agents.has(name) || ctx.teams.has(name) ? "mention" : null
  }
  if (!ctx.agents.has(name)) return null
  return ctx.members.has(name) ? "mention" : "outsider"
}

// Marks @mentions and #channels in `masked` (the text with its code blanked),
// offsetting them by `base` into the whole draft.
function scan(masked, base, ctx, marks) {
  for (let i = 0; i < masked.length; i++) {
    const ch = masked[i]
    if (ch !== "@" && ch !== "#") continue
    const prev = i > 0 ? masked[i - 1] : ""
    if (prev && (ch === "@" ? BEFORE_MENTION : BEFORE_CHANNEL).test(prev)) continue
    NAME.lastIndex = i + 1
    const match = NAME.exec(masked)
    if (!match) continue
    const name = match[0].toLowerCase()
    const kind = ch === "@" ? mentionKind(name, ctx) : ctx.channels.has(name) ? "channel" : null
    if (kind) marks.push([base + i, base + i + 1 + match[0].length, kind])
    i += match[0].length
  }
}

// An agent wins a name collision with a team, as on the server.
function mentionKind(name, ctx) {
  if (ctx.agents.has(name)) return ctx.members.has(name) ? "mention" : "outsider"
  const team = ctx.teams.get(name)
  if (!team) return null
  return team.some(member => ctx.members.has(member)) ? "mention" : "outsider"
}

function build(text, marks) {
  const tokens = []
  let at = 0
  marks.sort((a, b) => a[0] - b[0])
  for (const [start, end, kind] of marks) {
    if (start > at) tokens.push({kind: "plain", text: text.slice(at, start)})
    tokens.push({kind, text: text.slice(start, end)})
    at = end
  }
  if (at < text.length) tokens.push({kind: "plain", text: text.slice(at)})
  return tokens
}

// The draft with its code (fenced blocks, inline spans) replaced by spaces,
// unit for unit. The same rules as Canopy.Messages.CodeMask; see its moduledoc.
export function maskCode(text) {
  if (text.indexOf("`") < 0 && text.indexOf("~~~") < 0) return text
  const ranges = codeRanges(text)
  if (ranges.length === 0) return text
  let out = ""
  let at = 0
  for (const [from, to] of ranges) {
    out += text.slice(at, from) + " ".repeat(to - from)
    at = to
  }
  return out + text.slice(at)
}

function codeRanges(text) {
  const ranges = []
  let fence = null
  let from = 0
  let offset = 0
  for (const line of text.split("\n")) {
    const stop = offset + line.length
    if (fence) {
      if (closesFence(line, fence)) {
        ranges.push([fence.from, stop])
        fence = null
        from = stop + 1
      }
    } else if (line.trim() === "") {
      spans(text, from, offset, ranges)
      from = stop + 1
    } else {
      const open = OPEN_FENCE.exec(line)
      if (open && !(open[1][0] === "`" && open[2].includes("`"))) {
        spans(text, from, offset, ranges)
        fence = {from: offset, char: open[1][0], length: open[1].length}
      }
    }
    offset = stop + 1
  }
  if (fence) ranges.push([fence.from, text.length])
  else spans(text, from, text.length, ranges)
  return ranges.sort((a, b) => a[0] - b[0])
}

function closesFence(line, fence) {
  const trimmed = line.trim()
  if (trimmed.length < fence.length) return false
  for (const ch of trimmed) if (ch !== fence.char) return false
  return true
}

// Inline code spans in text[from, to), a paragraph with no blank lines. A run
// of N backticks closes on the next run of exactly N.
function spans(text, from, to, ranges) {
  let i = from
  while (i < to) {
    const ch = text[i]
    if (ch === "\\") {
      i += 2
      continue
    }
    if (ch !== "`") {
      i++
      continue
    }
    const n = run(text, i, to)
    const close = closer(text, i + n, to, n)
    if (close < 0) {
      i += n
    } else {
      ranges.push([i, close + n])
      i = close + n
    }
  }
}

function closer(text, i, to, n) {
  while (i < to) {
    const pos = text.indexOf("`", i)
    if (pos < 0 || pos >= to) return -1
    const m = run(text, pos, to)
    if (m === n) return pos
    i = pos + m
  }
  return -1
}

function run(text, pos, to) {
  let end = pos
  while (end < to && text[end] === "`") end++
  return end - pos
}
