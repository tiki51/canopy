// Matching and ranking for the command palette. No DOM: the e2e suite imports
// this module straight into Node (e2e/tests/command-palette-match.spec.ts).
//
// The query is split on whitespace and every token must match some field of
// an item. Per token, case-insensitive: the whole field 1000, a prefix 800, a
// word start (after - _ / . space @ #) 600, a substring 400, the letters in
// order 100 plus up to 99 for how many sit together. Letters in order count
// only in an item's first field (its name): in a role or a keyword list they
// match almost anything. An item's score is the sum over its tokens, plus
// bonuses: recently visited (up to +300), in the current repository +40, cards
// waiting +60, mentions +40; archived -250 and the channel you are in -100.

export const EXACT = 1000
export const PREFIX = 800
export const BOUNDARY = 600
export const SUBSTRING = 400
export const SUBSEQUENCE = 100

const RECENT_MAX = 20
const BOUNDARY_CHARS = "-_/. @#"

export function tokens(query) {
  return String(query || "").toLowerCase().split(/\s+/).filter(Boolean)
}

// The best score of one (lower-case) token against one field, or null;
// `loose: false` leaves out letters-in-order matches.
export function tokenScore(token, field, loose = true) {
  if (!field) return null
  const text = String(field).toLowerCase()
  if (text === token) return EXACT
  if (text.startsWith(token)) return PREFIX

  let at = text.indexOf(token)
  if (at !== -1) {
    while (at !== -1) {
      if (BOUNDARY_CHARS.includes(text[at - 1])) return BOUNDARY
      at = text.indexOf(token, at + 1)
    }
    return SUBSTRING
  }
  if (!loose) return null

  // the token's letters in order; adjacent pairs earn the contiguity bonus
  let from = 0
  let last = -2
  let adjacent = 0
  for (const char of token) {
    const found = text.indexOf(char, from)
    if (found === -1) return null
    if (found === last + 1) adjacent++
    last = found
    from = found + 1
  }
  const pairs = token.length - 1
  return SUBSEQUENCE + (pairs > 0 ? Math.floor((99 * adjacent) / pairs) : 0)
}

// The score of a whole query against an item's fields, or null when some
// token matches no field. An empty query matches everything with 0.
export function score(query, fields) {
  const list = Array.isArray(query) ? query : tokens(query)
  let total = 0
  for (const token of list) {
    let best = null
    for (let i = 0; i < fields.length; i++) {
      const s = tokenScore(token, fields[i], i === 0)
      if (s !== null && (best === null || s > best)) best = s
    }
    if (best === null) return null
    total += best
  }
  return total
}

// Ranks items for a query. An item is `{key, fields, archived?, channelId?,
// repoId?}`; `recents` is a most-recent-first list of keys, `badges` maps a
// channel id to [unread, mentions, waiting], `context` is `{channel_id,
// repo_id}`. Returns `[{item, score}]`, best first, unmatched items dropped;
// ties keep the items' order.
export function rank(items, query, {recents = [], badges = {}, context = {}} = {}) {
  const list = tokens(query)
  const recency = new Map()
  recents.slice(0, RECENT_MAX).forEach((key, i) => {
    if (!recency.has(key)) recency.set(key, i)
  })

  const out = []
  items.forEach((item, order) => {
    const base = score(list, item.fields || [])
    if (base === null) return
    out.push({item, score: base + bonus(item, recency, badges, context), order})
  })
  out.sort((a, b) => b.score - a.score || a.order - b.order)
  return out.map(({item, score}) => ({item, score}))
}

function bonus(item, recency, badges, context) {
  let total = 0
  if (recency.has(item.key)) total += Math.round(300 * (1 - recency.get(item.key) / RECENT_MAX))
  if (context.repo_id && item.repoId === context.repo_id) total += 40
  const badge = item.channelId && badges[item.channelId]
  if (badge) {
    if (badge[2] > 0) total += 60
    if (badge[1] > 0) total += 40
  }
  if (item.archived) total -= 250
  if (context.channel_id && item.channelId === context.channel_id) total -= 100
  return total
}
