#!/usr/bin/env bash
#
# YATZ openings monitor
# ---------------------
# Logs in to Taronga YATZ (Volgistics VicNet), scans the calendar for NEW
# sign-up openings, and messages them to you via a Telegram bot. Designed to
# run on a GitHub Actions cron, but runs anywhere with bash + curl + jq.
#
# State (slots already seen) is kept in state.json so repeated runs only
# alert on genuinely new openings. On the very first run (no state.json) it
# silently seeds the baseline without alerting.
#
# Required env (secrets):     YATZ_EMAIL  YATZ_PASSWORD
# Telegram env (live alerts): TELEGRAM_BOT_TOKEN  TELEGRAM_CHAT_ID
# Optional env:               MONTHS_AHEAD(3)  STATE_FILE(state.json)  DRY_RUN(unset)
#                             YATZ_FROM  YATZ_API_KEY  YATZ_CLIENT_VERSION

set -euo pipefail

# Load a local .env for convenience when running by hand (git-ignored).
# On GitHub Actions there's no .env, so real secrets come from the environment.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

# ---------------------------------------------------------------- config ----
YATZ_FROM="${YATZ_FROM:-201756}"
YATZ_API_KEY="${YATZ_API_KEY:-6wRWFhd.aVNctG6h4Y5f4Kp4furHA4CypFdSrtE7}"   # static app key, shipped in the public JS bundle
YATZ_CLIENT_VERSION="${YATZ_CLIENT_VERSION:-1.8.0}"
MONTHS_AHEAD="${MONTHS_AHEAD:-3}"            # scan current month + this many ahead
STATE_FILE="${STATE_FILE:-state.json}"
DRY_RUN="${DRY_RUN:-}"                       # set to anything to print instead of texting
BASE="https://www.volgistics.com/api/vicnet"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

: "${YATZ_EMAIL:?YATZ_EMAIL is required}"
: "${YATZ_PASSWORD:?YATZ_PASSWORD is required}"

# --------------------------------------------------------------- telegram ---
send_telegram() {
  local body="$1"
  if [ -n "$DRY_RUN" ]; then
    log "[DRY_RUN] would send: $body"
    return 0
  fi
  : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN required to send}"
  : "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID required to send}"
  local resp code
  resp=$(curl -sS -w '\n%{http_code}' -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${body}" \
    --data-urlencode "disable_web_page_preview=true") || { log "Telegram request errored"; return 1; }
  code=$(printf '%s' "$resp" | tail -n1)
  if [ "$code" = "200" ]; then
    log "Telegram sent (200)"
  else
    log "Telegram FAILED (HTTP $code): $(printf '%s' "$resp" | sed '$d' | head -c 300)"
    return 1
  fi
}

# ------------------------------------------------------------------ login ---
login_body=$(jq -n --arg from "$YATZ_FROM" --arg email "$YATZ_EMAIL" --arg pw "$YATZ_PASSWORD" \
  '{FROM:$from, email:$email, password:$pw}')
login_json=$(curl -sS -X POST "$BASE/auth/log-in?platform=web" \
  -A "$UA" \
  -H "content-type: application/json" \
  -H "x-api-key: $YATZ_API_KEY" \
  -H "x-client-version: $YATZ_CLIENT_VERSION" \
  -H "origin: https://www.volgistics.com" \
  -H "accept: application/json, text/plain, */*" \
  --data "$login_body") || die "login request failed"

JWT=$(printf '%s' "$login_json" | jq -r '.jwt // empty')
[ -n "$JWT" ] || die "login failed (no jwt returned) — check YATZ_EMAIL/YATZ_PASSWORD"
log "logged in"

# ----------------------------------------------- fetch months & collect -----
year=$((10#$(date -u +%Y)))
month=$((10#$(date -u +%m)))
all_entries='[]'
for i in $(seq 0 "$MONTHS_AHEAD"); do
  m=$(( (month - 1 + i) % 12 + 1 ))
  y=$(( year + (month - 1 + i) / 12 ))
  mm=$(printf '%02d' "$m")
  url="$BASE/schedule?date=${y}-${mm}-15T04:00:00.000Z&timeSpan=0&kind=volunteer&daySearch=0&firstCall=false&currView=month&platform=web"
  resp=$(curl -sS "$url" -A "$UA" \
    -H "authorization: Bearer $JWT" \
    -H "x-api-key: $YATZ_API_KEY" \
    -H "x-client-version: $YATZ_CLIENT_VERSION" \
    -H "accept: application/json, text/plain, */*") || { log "fetch ${y}-${mm} failed, skipping"; continue; }
  entries=$(printf '%s' "$resp" | jq -c '.schedule // []' 2>/dev/null || echo '[]')
  all_entries=$(jq -c -n --argjson a "$all_entries" --argjson b "$entries" '$a + $b')
  log "fetched ${y}-${mm}: $(printf '%s' "$entries" | jq 'length') entries"
done

# --------------------------------------- compute current open slots ---------
# An "open" slot = type=="openings", has spots left, and you're NOT already
# scheduled on that same slotNum.
current=$(printf '%s' "$all_entries" | jq -c '
  (map(select(.meta.type=="scheduled") | .meta.slotNum)) as $booked
  | map(. as $e
        | select($e.meta.type=="openings"
                 and (($e.meta.volsNeeded // 0) > 0)
                 and (($booked | index($e.meta.slotNum)) == null)))
  | map({ slotNum: .meta.slotNum, title: .title, start: .start,
          volsNeeded: .meta.volsNeeded, place: (.meta.placeName // .meta.siteName // ""),
          note: (.meta.openingNote // "") })
  | unique_by(.slotNum)')

current_ids=$(printf '%s' "$current" | jq -c 'map(.slotNum)')
log "current open slots: $(printf '%s' "$current" | jq 'length')  -> ids $current_ids"

# ----------------------------------------------------- diff vs state --------
first_run=0
prev_ids='[]'
if [ -f "$STATE_FILE" ]; then
  prev_ids=$(jq -c '.openSlots // []' "$STATE_FILE" 2>/dev/null || echo '[]')
else
  first_run=1
fi

new_slots=$(printf '%s' "$current" | jq -c --argjson prev "$prev_ids" '
  map(. as $e | select(($prev | index($e.slotNum)) == null))')
new_count=$(printf '%s' "$new_slots" | jq 'length')

# ----------------------------------------------------- alert ----------------
if [ "$first_run" = "1" ]; then
  log "first run — seeding baseline of $(printf '%s' "$current" | jq 'length') open slot(s), no alerts sent"
elif [ "$new_count" -gt 0 ]; then
  log "$new_count NEW opening(s) — alerting"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    msg=$(printf '%s' "$row" | jq -r '
      "YATZ opening: \(.title) — \(.start[0:10]) \(.start[11:16]) — \(.volsNeeded) spot(s)"
      + (if .note != "" then " (\(.note))" else "" end)
      + ". Sign up: https://www.volgistics.com/vicnet/201756"')
    send_telegram "$msg" || log "alert send failed for slot $(printf '%s' "$row" | jq -r '.slotNum') (will retry next run)"
  done < <(printf '%s' "$new_slots" | jq -c '.[]')
else
  log "no new openings"
fi

# ----------------------------------------------------- write state ----------
# No timestamp on purpose: the file only changes when openings change, so the
# Actions workflow commits only on real changes (not every run).
jq -n --argjson ids "$current_ids" --argjson detail "$current" \
  '{ openSlots: ($ids | sort), detail: ($detail | sort_by(.slotNum)) }' > "$STATE_FILE"
log "state written to $STATE_FILE"
