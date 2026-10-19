#!/bin/bash
# A stand-in for the `codex` binary in tests. `--version` and `login status`
# answer at once; `app-server` speaks JSON-RPC lines on stdin/stdout.
#
# With $FAKE_CODEX_SCRIPT (a jsonl of directives), app-server plays it:
#   {"await_thread":true}      answer thread/start or thread/resume (a resume replays
#                              earlier usage under an earlier turn id; $THREAD follows it)
#   {"await":"<method>"}       read stdin until a request with that method; its
#                              id becomes $ID; routine requests meanwhile are answered
#   {"await_response":<id>}    read stdin until our server request <id> is answered
#   {"send":{...}}             print the object with $ID, $THREAD, $TURN, $STEER (the
#                              last steer's client id), $REPO (the cwd) and $HOME replaced
#   {"include":"<file>"}       play another script from the same directory
#   {"sleep":<ms>}             pause
#   {"exit":<n>}               exit now with status n
# then waits for stdin to close and exits 0, as Codex does.
#
# Without a script it answers on its own: initialize, account/read, model/list,
# thread/start, thread/resume, thread/inject_items, turn/start (a short text
# turn), thread/turns/list; anything else gets a -32601 error.
#
#   FAKE_CODEX_ACCOUNT   chatgpt-pro (default) | chatgpt-plus | api_key | none
#   FAKE_CODEX_MODELS    a JSON file holding model/list's result, or "fail"
#                        (default: codex_fixtures/models.json)
#   FAKE_CODEX_DELAY_MS  delay before each built-in reply
#   FAKE_CODEX_RESUME    not_found: thread/resume fails as for a thread with no rollout
#   FAKE_CODEX_THREAD    the id thread/start names (default a fixed UUIDv7)
#   FAKE_CODEX_VERSION   what --version reports (default 9.9.9)
#   FAKE_CODEX_LOG       append ARGV, ENV names (and the token's sha256) and every
#                        stdin line here
dir="$(cd "$(dirname "$0")" && pwd)/codex_fixtures"

case "$1" in
  --version) echo "codex-cli ${FAKE_CODEX_VERSION:-9.9.9}"; exit 0 ;;
  login)
    if [ "$FAKE_CODEX_ACCOUNT" = "none" ]; then echo "Not logged in"; exit 1; fi
    echo "Logged in using ChatGPT"; exit 0 ;;
  app-server) ;;
  *) echo "fake codex: unknown command $1" >&2; exit 2 ;;
esac

THREAD="${FAKE_CODEX_THREAD:-019a0000-0000-7000-8000-000000000001}"
TURN="019a0000-0000-7000-8000-0000000000aa"
ID=""

log() { if [ -n "$FAKE_CODEX_LOG" ]; then printf '%s\n' "$1" >> "$FAKE_CODEX_LOG"; fi; }

log "ARGV $*"
if [ -n "$FAKE_CODEX_LOG" ]; then
  names=$(env | sed -nE 's/^(CANOPY_[A-Z_]*|CODEX_HOME)=.*/\1/p' | sort | tr '\n' ' ')
  log "ENV $names"
  if [ -n "$CANOPY_MCP_TOKEN" ]; then
    log "TOKEN_SHA256 $(printf '%s' "$CANOPY_MCP_TOKEN" | shasum -a 256 | cut -d' ' -f1)"
  fi
  if [ -n "$CODEX_HOME" ]; then log "CODEX_HOME $CODEX_HOME"; fi
fi

say() { printf '%s\n' "$1"; }

delay() {
  if [ -n "$FAKE_CODEX_DELAY_MS" ]; then sleep "$(echo "scale=3; $FAKE_CODEX_DELAY_MS/1000" | bc)"; fi
}

# Reads one stdin line into $line (exits 0 on EOF) and logs it.
next_line() {
  if ! IFS= read -r line; then exit 0; fi
  log "STDIN $line"
}

method_of() { [[ "$1" =~ \"method\":\"([^\"]+)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }
id_of() { [[ "$1" =~ \"id\":([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
thread_of() { [[ "$1" =~ \"threadId\":\"([^\"]+)\" ]] && printf '%s' "${BASH_REMATCH[1]}"; }

subst() {
  local s="$1"
  s="${s//\$ID/$ID}"
  s="${s//\$THREAD/$THREAD}"
  s="${s//\$TURN/$TURN}"
  s="${s//\$STEER/$STEER}"
  s="${s//\$REPO/$PWD}"
  s="${s//\$HOME/$HOME}"
  printf '%s' "$s"
}

# -- Built-in ----------------------------------------------------------------

initialized() {
  say "{\"id\":$1,\"result\":{\"userAgent\":\"canopy/${FAKE_CODEX_VERSION:-9.9.9} (fake)\",\"codexHome\":\"${CODEX_HOME:-$HOME/.codex}\"}}"
}

account() {
  case "${FAKE_CODEX_ACCOUNT:-chatgpt-pro}" in
    none) say "{\"id\":$1,\"result\":{\"account\":null,\"requiresOpenaiAuth\":true}}" ;;
    api_key) say "{\"id\":$1,\"result\":{\"account\":{\"type\":\"apiKey\"},\"requiresOpenaiAuth\":true}}" ;;
    chatgpt-plus) say "{\"id\":$1,\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":\"dev@example.com\",\"planType\":\"plus\"},\"requiresOpenaiAuth\":true}}" ;;
    *) say "{\"id\":$1,\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":\"dev@example.com\",\"planType\":\"pro\"},\"requiresOpenaiAuth\":true}}" ;;
  esac
}

models() {
  local file="${FAKE_CODEX_MODELS:-$dir/models.json}"
  if [ "$file" = "fail" ]; then
    say "{\"id\":$1,\"error\":{\"code\":-32603,\"message\":\"model list unavailable\"}}"
  else
    say "{\"id\":$1,\"result\":$(tr -d '\n' < "$file")}"
  fi
}

thread() {
  say "{\"id\":$1,\"result\":{\"thread\":{\"id\":\"$2\",\"cliVersion\":\"${FAKE_CODEX_VERSION:-9.9.9}\",\"path\":\"/tmp/rollout-$2.jsonl\"},\"model\":\"gpt-5-codex\",\"approvalPolicy\":\"on-request\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}"
}

text_turn() {
  say "{\"id\":$1,\"result\":{\"turn\":{\"id\":\"$TURN\",\"status\":\"inProgress\",\"items\":[]}}}"
  say "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"$THREAD\",\"turn\":{\"id\":\"$TURN\",\"status\":\"inProgress\",\"items\":[]}}}"
  say "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"$THREAD\",\"turnId\":\"$TURN\",\"item\":{\"type\":\"agentMessage\",\"id\":\"msg-1\",\"text\":\"Done.\",\"phase\":\"final_answer\"}}}"
  say "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"$THREAD\",\"turnId\":\"$TURN\",\"tokenUsage\":{\"total\":{\"totalTokens\":1100,\"inputTokens\":1000,\"cachedInputTokens\":400,\"cacheWriteInputTokens\":0,\"outputTokens\":100,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":1100,\"inputTokens\":1000,\"cachedInputTokens\":400,\"cacheWriteInputTokens\":0,\"outputTokens\":100,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}}}"
  say "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"$THREAD\",\"turn\":{\"id\":\"$TURN\",\"status\":\"completed\",\"items\":[],\"error\":null}}}"
}

# -- Scripted ----------------------------------------------------------------

# While a script waits for one request, the routine ones are answered as the
# built-in server would (initialize, inject_items, account/read, model/list).
auto_answer() {
  local m="$(method_of "$1")" id="$(id_of "$1")"
  [ -z "$m" ] || [ -z "$id" ] && return 1
  case "$m" in
    initialize) initialized "$id" ;;
    thread/inject_items) say "{\"id\":$id,\"result\":{}}" ;;
    account/read) account "$id" ;;
    model/list) models "$id" ;;
    *) return 1 ;;
  esac
}

# Waits for thread/start or thread/resume and answers it; a resume replays the
# thread's earlier usage under an earlier turn's id, as Codex does.
await_thread() {
  while :; do
    next_line
    local m="$(method_of "$line")" id="$(id_of "$line")"
    case "$m" in
      thread/start) ID="$id"; thread "$id" "$THREAD"; return ;;
      thread/resume)
        ID="$id"
        local requested="$(thread_of "$line")"
        if [ "$FAKE_CODEX_RESUME" = "not_found" ]; then
          say "{\"id\":$id,\"error\":{\"code\":-32600,\"message\":\"no rollout found for thread id $requested\"}}"
        else
          THREAD="$requested"
          thread "$id" "$THREAD"
          say "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"$THREAD\",\"turnId\":\"019a0000-0000-7000-8000-0000000000a0\",\"tokenUsage\":{\"total\":{\"totalTokens\":5500,\"inputTokens\":5000,\"cachedInputTokens\":2000,\"cacheWriteInputTokens\":0,\"outputTokens\":500,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":1100,\"inputTokens\":1000,\"cachedInputTokens\":400,\"cacheWriteInputTokens\":0,\"outputTokens\":100,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}}}"
          return
        fi ;;
      *) auto_answer "$line" ;;
    esac
  done
}

play() {
  local file="$1" d
  while IFS= read -r d <&3 || [ -n "$d" ]; do
    case "$d" in
      '{"await_thread":'*) await_thread ;;
      '{"await":"'*)
        local want="${d#\{\"await\":\"}"; want="${want%\"\}}"
        while :; do
          next_line
          if [ "$(method_of "$line")" = "$want" ] && [ -n "$(id_of "$line")" ]; then
            ID="$(id_of "$line")"
            if [[ "$line" =~ \"clientUserMessageId\":\"([^\"]+)\" ]]; then STEER="${BASH_REMATCH[1]}"; fi
            break
          fi
          auto_answer "$line"
        done ;;
      '{"await_response":'*)
        local rid="${d#\{\"await_response\":}"; rid="${rid%\}}"
        while :; do
          next_line
          if [ -z "$(method_of "$line")" ] && [ "$(id_of "$line")" = "$rid" ]; then break; fi
          auto_answer "$line"
        done ;;
      '{"send":'*)
        local body="${d#\{\"send\":}"; body="${body%\}}"
        say "$(subst "$body")" ;;
      '{"include":"'*)
        local inc="${d#\{\"include\":\"}"; inc="${inc%\"\}}"
        case "$inc" in
          /*) play "$inc" ;;
          *) play "$(dirname "$file")/$inc" ;;
        esac ;;
      '{"sleep":'*)
        local ms="${d#\{\"sleep\":}"; ms="${ms%\}}"
        sleep "$(echo "scale=3; $ms/1000" | bc)" ;;
      '{"exit":'*)
        local code="${d#\{\"exit\":}"; code="${code%\}}"
        exit "$code" ;;
    esac
  done 3< "$file"
}

if [ -n "$FAKE_CODEX_SCRIPT" ]; then
  play "$FAKE_CODEX_SCRIPT"
  while IFS= read -r line; do log "STDIN $line"; done
  exit 0
fi

# -- Built-in loop -----------------------------------------------------------

while :; do
  next_line
  m="$(method_of "$line")"
  id="$(id_of "$line")"
  [ -z "$id" ] && continue
  [ -z "$m" ] && continue
  delay
  case "$m" in
    initialize) initialized "$id" ;;
    account/read) account "$id" ;;
    model/list) models "$id" ;;
    thread/start) thread "$id" "$THREAD" ;;
    thread/resume)
      requested="$(thread_of "$line")"
      if [ "$FAKE_CODEX_RESUME" = "not_found" ]; then
        say "{\"id\":$id,\"error\":{\"code\":-32600,\"message\":\"no rollout found for thread id $requested\"}}"
      else
        THREAD="$requested"
        thread "$id" "$THREAD"
      fi ;;
    thread/inject_items) say "{\"id\":$id,\"result\":{}}" ;;
    turn/start) text_turn "$id" ;;
    thread/turns/list) say "{\"id\":$id,\"result\":{\"data\":[],\"nextCursor\":null,\"backwardsCursor\":null}}" ;;
    *) say "{\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"unknown method $m\"}}" ;;
  esac
done
