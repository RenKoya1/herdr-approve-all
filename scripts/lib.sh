# Shared helpers. Sourced by the action/event scripts.

HERDR="${HERDR_BIN_PATH:-herdr}"

# Tunables (env-overridable, mainly so the stub test can shrink the waits).
APPROVE_MAX_SENDS="${APPROVE_MAX_SENDS:-5}"       # confirm keys per pane, per run
APPROVE_LEAVE_TIMEOUT_MS="${APPROVE_LEAVE_TIMEOUT_MS:-1200}"
APPROVE_SETTLE_SEC="${APPROVE_SETTLE_SEC:-0.15}"  # let a queued prompt paint
APPROVE_SCRAPE_FALLBACK="${APPROVE_SCRAPE_FALLBACK:-1}"

# json_eval <jq filter> <python body>: run the jq filter when jq is available
# (instant), else the python equivalent (interpreter startup can cost ~1s).
json_eval() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1"
  else
    python3 -c "
import sys, json
d = json.load(sys.stdin)
$2"
  fi
}

# keys_for <agent>: keys to send to approve that agent's prompt.
# Enter confirms the highlighted default (Yes/Allow) in every supported agent's
# blocked prompt (claude, codex, gemini, ...). Override per agent with a line
# "<agent>=<key> [key...]" in $HERDR_PLUGIN_CONFIG_DIR/keys.conf, e.g.
#   codex=y enter
keys_for() {
  local conf="${HERDR_PLUGIN_CONFIG_DIR:-}/keys.conf" line
  if [ -f "$conf" ]; then
    line=$(grep -m1 "^${1}=" "$conf" 2>/dev/null || true)
    if [ -n "$line" ]; then
      printf '%s' "${line#*=}"
      return
    fi
  fi
  printf 'enter'
}

file_mtime() {
  local mt
  # Capture each probe: GNU stat -f can print filesystem info before failing.
  # Only emit a valid timestamp, since callers use it in shell arithmetic.
  if mt=$(stat -c %Y "$1" 2>/dev/null); then
    case "$mt" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$mt"; return 0 ;;
    esac
  fi
  if mt=$(stat -f %m "$1" 2>/dev/null); then
    case "$mt" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$mt"; return 0 ;;
    esac
  fi
  date +%s
}

# take_lock <dir> <max_age_seconds>: mkdir-based mutex. A lock older than
# max_age is assumed to belong to a killed run and is taken over, so a crash can
# never wedge the plugin permanently.
take_lock() {
  local dir="$1" max="$2" now mt
  if mkdir "$dir" 2>/dev/null; then
    return 0
  fi
  now=$(date +%s)
  mt=$(file_mtime "$dir")
  if [ $((now - mt)) -lt "$max" ]; then
    return 1
  fi
  rmdir "$dir" 2>/dev/null || true
  mkdir "$dir" 2>/dev/null
}

pane_lock_path() {
  printf '%s/herdr-approve-all.pane.%s' "${TMPDIR:-/tmp}" \
    "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_')"
}

# agent_status <pane>: current status, or empty when the pane is gone.
agent_status() {
  "$HERDR" agent get "$1" 2>/dev/null | json_eval \
    '.result.agent.agent_status // empty' \
    'print(d.get("result", {}).get("agent", {}).get("agent_status", ""))'
}

# prompt_visible <pane>: true when the VISIBLE screen shows a live prompt.
# herdr derives agent_status by scraping the terminal, so a real prompt can lose
# to a higher-priority rule (a spinner in the OSC title, the composer's own idle
# rule) and the pane reports working/idle/unknown while it sits there waiting.
# Matching is deliberately narrow: the "esc to cancel" footer only renders while
# a dialog is live, and the second pattern pins it to a choice prompt.
prompt_visible() {
  local out
  [ "$APPROVE_SCRAPE_FALLBACK" = "1" ] || return 1
  out=$("$HERDR" agent read "$1" --source visible --lines 24 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -qi 'esc to cancel' || return 1
  printf '%s\n' "$out" | grep -qiE '^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]|enter to (confirm|select)'
}

needs_approval() {
  [ "$(agent_status "$1")" = "blocked" ] && return 0
  prompt_visible "$1"
}

# approve_pane <pane> <agent>: send the confirm key, then VERIFY the pane left
# the blocked state instead of assuming it did. Prompts that stack up behind the
# one just answered (a fleet of subagents each asking for permission) are
# drained in the same run: herdr reports blocked -> blocked with no status
# change, so no second event ever arrives and, before this, no second key was
# ever sent. Prints "1" when the pane ends the run un-blocked, "0" when it is
# still waiting, and "-" when it never needed a key at all.
approve_pane() {
  local pane="$1" agent="$2" sent=0
  while [ "$sent" -lt "$APPROVE_MAX_SENDS" ]; do
    needs_approval "$pane" || break
    # shellcheck disable=SC2046
    "$HERDR" agent send-keys "$pane" $(keys_for "$agent") >/dev/null 2>&1 || break
    sent=$((sent + 1))
    "$HERDR" agent wait "$pane" --until idle --until working --until done \
      --timeout "$APPROVE_LEAVE_TIMEOUT_MS" >/dev/null 2>&1 || true
    sleep "$APPROVE_SETTLE_SEC"
  done
  if [ "$sent" -eq 0 ]; then
    printf -- '-'
  elif needs_approval "$pane"; then
    printf 0
  else
    printf 1
  fi
}
