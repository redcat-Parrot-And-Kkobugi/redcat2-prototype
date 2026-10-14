#!/usr/bin/env bash
# =============================================================================
#  scripts/auditor.sh <name|slug> — epistemic / conclusiveness auditor loop.
#
#  Periodically (AUDITOR_INTERVAL, default 420s = 7 min) reads a running hunt's
#  RAW logs and has an INDEPENDENT reviewer (opus) judge ONE thing: is any
#  negative the solver is leaning on (a refuted/frozen high-impact hypothesis, a
#  vector it treats as dead) actually CONCLUSIVE, or was it abandoned on an
#  INCONCLUSIVE result (a test that never reached the mechanism — FAULT/timeout/
#  transport/tooling)? It writes:
#    runs/<slug>/auditor.md          — latest finding; the hook PUSHES the solver to read it
#    runs/<slug>/logs/auditor.jsonl  — full history (one JSON line per tick)
#  It is the complement to oversee: oversee judges STRATEGY (rabbit-hole/priority),
#  this judges EVIDENCE QUALITY (premature surrender on an untested mechanism). It
#  never touches the target — raw logs in, advice out. Mirrors oversee.sh.
#
#    scripts/auditor.sh Nimbus
#    AUDITOR_INTERVAL=300 scripts/auditor.sh Nimbus
#    ONESHOT=1 scripts/auditor.sh Nimbus              # one audit then exit
#    AUDITOR_MODEL=claude-opus-4-8 scripts/auditor.sh Nimbus
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
unset ANTHROPIC_API_KEY
: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env}"
# mirror lib/env.sh cache policy so ticks reuse the byte-stable prefix (OAuth makes 1h eligible)
: "${CLAUDE_CODE_PROMPT_CACHE_TTL:=1h}"; : "${DISABLE_AUTOUPDATER:=1}"
export CLAUDE_CODE_PROMPT_CACHE_TTL DISABLE_AUTOUPDATER

usage(){ echo "usage: auditor.sh [-s|--slug <name>] [-m|--model <model>] [-i|--interval <sec>] [--oneshot] [<slug>]" >&2; }
_slug="" _model="" _interval="" _oneshot=""; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--slug)     [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage; exit 2; }; _slug="$2"; shift 2 ;;
    -m|--model)    [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage; exit 2; }; _model="$2"; shift 2 ;;
    -i|--interval) [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage; exit 2; }; _interval="$2"; shift 2 ;;
    --oneshot)     _oneshot=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
    -*)            echo "unknown option: $1" >&2; usage; exit 2 ;;
    *)             pos+=("$1"); shift ;;
  esac
done
[ -z "$_slug" ] && [ "${#pos[@]}" -ge 1 ] && _slug="${pos[0]}"
NAME="$_slug"
MODEL="${_model:-${AUDITOR_MODEL:-claude-opus-4-8}}"
INTERVAL="${_interval:-${AUDITOR_INTERVAL:-420}}"
[ -n "$_oneshot" ] && ONESHOT=1
RUNDIR="$(rc2_resolve_rundir "$NAME")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "${r:-}no run dir${NAME:+ for '$NAME'}${n:-} (pass -s <name>, or start a hunt first)"; exit 1; }
NAME="$(basename "$RUNDIR")"
AUD="$RUNDIR/auditor.md"
HIST="$RUNDIR/logs/auditor.jsonl"
SYS="$ROOT/AUDITOR.md"
mkdir -p "$RUNDIR/logs"

# _aud_inconclusive_signals — scan the recent post results for the signatures of a test that
# never reached the mechanism (the cheap prefilter the opus pass then adjudicates). Best-effort.
_aud_inconclusive_signals(){
  local tj="$RUNDIR/logs/tools.jsonl" of
  [ -f "$tj" ] || return 0
  # non-zero exits in the last 60 post events
  jq -r 'select(.event=="post" and (.exit!=null) and (.exit!=0)) | "  exit=\(.exit) \((.command // .tool)[0:120])"' "$tj" 2>/dev/null | tail -12
  # raw outputs whose content screams "never ran" — FAULT/timeout/transport/offline/cyber
  jq -r 'select(.event=="post") | .out_file' "$tj" 2>/dev/null | tail -60 | while read -r of; do
    [ -n "$of" ] && [ -f "$RUNDIR/logs/$of" ] || continue
    grep -liE 'FAULT|timed out|timeout|Connection (refused|reset|timed)|curl: \(2[78]\)|curl: \(56\)|unpullable|failed to resolve image|safeguards flagged|\[cyber\]|could not connect|empty reply' "$RUNDIR/logs/$of" 2>/dev/null \
      | sed "s#$RUNDIR/logs/#    inconclusive-signal in logs/#"
  done | sort -u | tail -15
}

build_digest(){
  local tj="$RUNDIR/logs/tools.jsonl" elapsed="?" now; now=$(date +%s)
  [ -f "$RUNDIR/logs/meta.env" ] && { . "$RUNDIR/logs/meta.env" 2>/dev/null; [ -n "${start_epoch:-}" ] && elapsed="$(( (now-start_epoch)/60 ))m"; }
  rc2_load_target "$RUNDIR" 2>/dev/null || true

  echo "# AUDIT DIGEST (evidence-quality review — judge from the RAW logs, not the solver's stated confidence)"
  echo "machine=${machine_name:-$NAME} ip=${target_ip:-?} os=${os_hint:-?} difficulty=${difficulty:-?} elapsed=${elapsed}"
  echo "hunt_running=$(pgrep -f "hunt .*$NAME|claude -p .*$NAME" >/dev/null 2>&1 && echo yes || echo no)"
  echo "RC2_UNTESTABLE_MAX=${RC2_UNTESTABLE_MAX:-4}"
  echo
  echo "## flags.txt"; sed 's/^/  /' "$RUNDIR/flags.txt" 2>/dev/null
  echo
  echo "## REFUTED / FROZEN hypotheses (the negatives you are auditing — did each mechanism actually speak?)"
  awk '/^### H[0-9]/{keep=0} /^### H[0-9].*\[status:[[:space:]]*(refuted|frozen)/{keep=1} keep{print}' \
      "$RUNDIR/hypotheses.md" 2>/dev/null | sed 's/^/  /' | head -80
  echo
  echo "## recorded negatives (ledger.json — check claimed confidence/tested depth against the logs)"
  jq -r '.negatives[]? | "  - \(.fact)  [conf:\(.confidence // "?") · tested:\(.tested // "?")\(if .kind then " · kind:\(.kind)" else "" end)]"' "$RUNDIR/ledger.json" 2>/dev/null | head -30
  echo
  echo "## INCONCLUSIVE-candidate signals in recent results (a test that may never have reached the mechanism)"
  _aud_inconclusive_signals
  echo
  echo "## your prior audits (newest first — did the solver fix what you last flagged?)"
  if [ -s "$HIST" ]; then
    tail -3 "$HIST" | tac | jq -r '"  [#\(.review) \(.ts) \(.audit)/\(.class)] \((.verdict|gsub("[\n]";" "))[0:240])"' 2>/dev/null
  else echo "  (none yet — first audit)"; fi
  echo
  echo "## recent journal (tail — the solver's own account of why it moved on)"
  tail -30 "$RUNDIR/journal.md" 2>/dev/null | sed 's/^/  /'
  echo
  echo "## last 40 tool calls (ts tool | command[:200])"
  if [ -f "$tj" ]; then
    jq -r 'select(.event=="pre") | [.ts, .tool, ((.command // (.input|tostring))[0:200])] | @tsv' "$tj" 2>/dev/null | tail -40 | sed 's/^/  /'
  fi
}

# _auditor_review <model> — one reviewer pass (digest on stdin), verdict (or error text) on stdout.
_auditor_review(){
  timeout 300 claude -p \
      "This is an audit digest. Per the AUDITOR instructions: judge ONLY evidence quality — is any refuted/frozen vector actually CONCLUSIVE, or was it abandoned on an INCONCLUSIVE result (a test that never reached the mechanism)? Read the raw logs/tools.jsonl and logs/raw/*.out yourself to verify, then output ONLY the verdict in the specified format. Read-only tools (Read/Glob/Grep).
---
$(cat)" \
      --model "$1" --append-system-prompt "$(cat "$SYS")" \
      --allowedTools "Read Glob Grep" 2>&1
}
_auditor_failed(){ [ "$1" -ne 0 ] && return 0; printf '%s' "$2" | grep -qiE 'API Error|safeguards flagged|\[cyber\]|Request ID|reviewer call failed'; }
_auditor_cyber(){ printf '%s' "$1" | grep -qiE 'safeguards flagged|\[cyber\]|Cyber Verification'; }

# write_auditor <body> — write auditor.md with a bumped AUDITOR_TICK + the push header. Echoes new tick.
write_auditor(){
  local body="$1" ts cur new
  ts="$(rc2_utc)"
  cur="$(grep -oE '^AUDITOR_TICK: [0-9]+' "$AUD" 2>/dev/null | grep -oE '[0-9]+' | head -1)"; cur="${cur:-0}"; new=$((cur+1))
  { printf 'AUDITOR_TICK: %s   (%s · epistemic auditor)\n' "$new" "$ts"
    echo "# conclusiveness auditor (auto). SOLVER: a flagged negative you are leaning on rests on INCONCLUSIVE evidence — a test that never reached the mechanism. Act ONLY when AUDITOR_TICK changed since you last applied it (record the applied tick in journal.md). When newer: STOP, re-open the flagged VECTOR with the materially-different attempt in DO NEXT (or PARK it as untestable, naming the missing capability) — do NOT leave it recorded as a flat refutation."
    printf '%s\n' "$body"
  } > "$AUD" 2>/dev/null || true
  echo "$new"
}

assess(){
  local rev="$1" digest verdict ts audit class rc new
  digest="$(build_digest)"
  ts="$(date '+%F %T')"
  echo "${c:-}[auditor]${n:-} audit #$rev @ $ts (${MODEL}) ..."
  verdict="$(printf '%s\n' "$digest" | _auditor_review "$MODEL")"; rc=$?

  if _auditor_failed "$rc" "$verdict" && _auditor_cyber "$verdict" && [ -n "${AUDITOR_FALLBACK_MODEL:-}" ]; then
    echo "${y:-}   [cyber] auditor flagged — retrying once with AUDITOR_FALLBACK_MODEL=$AUDITOR_FALLBACK_MODEL${n:-}"
    verdict="$(printf '%s\n' "$digest" | _auditor_review "$AUDITOR_FALLBACK_MODEL")"; rc=$?
  fi

  if _auditor_failed "$rc" "$verdict"; then audit="error"; class="-"
  else
    audit="$(printf '%s' "$verdict" | grep -oiE 'AUDIT:[[:space:]]*(sound|misclassified)' | head -1 | grep -oiE 'sound|misclassified' | tr 'A-Z' 'a-z')"; audit="${audit:-unknown}"
    class="$(printf '%s' "$verdict" | grep -oiE 'CLASS:[[:space:]]*(conclusive-negative|inconclusive|untestable)' | head -1 | grep -oiE 'conclusive-negative|inconclusive|untestable' | tr 'A-Z' 'a-z')"; class="${class:--}"
  fi

  jq -cn --arg ts "$ts" --arg rev "$rev" --arg a "$audit" --arg cl "$class" --arg v "$verdict" \
     '{ts:$ts, review:($rev|tonumber), audit:$a, class:$cl, verdict:$v}' >> "$HIST" 2>/dev/null

  if [ "$audit" = "sound" ]; then
    echo "${g:-}   sound — every audited negative is conclusive (auditor.md untouched)${n:-}"; return 0
  fi
  if [ "$audit" != "misclassified" ]; then
    if _auditor_cyber "$verdict"; then echo "${r:-}   [cyber] auditor flagged by safeguards — auditor.md + tick UNCHANGED (set AUDITOR_FALLBACK_MODEL)${n:-}"
    elif [ "$audit" = "error" ]; then echo "${y:-}   auditor call failed — auditor.md + tick UNCHANGED (logged as error)${n:-}"
    else echo "${y:-}   auditor returned no parseable AUDIT — auditor.md + tick UNCHANGED${n:-}"; fi
    return 0
  fi

  new="$(write_auditor "$(printf '_audit #%s · model=%s_\n\n%s' "$rev" "$MODEL" "$verdict")")"
  echo "   ${r:-}MISCLASSIFIED${n:-} (class=$class) → wrote auditor.md (AUDITOR_TICK $new); hook will push the solver to read it"
  printf '%s\n' "$verdict" | sed -n '1,8p' | sed 's/^/   /'
}

echo "${c:-}[auditor]${n:-} watching $RUNDIR  (model=$MODEL interval=${INTERVAL}s)"
echo "${d:-}   audits evidence quality every ${INTERVAL}s; writes $AUD ONLY on a misclassified negative; every audit → $HIST ; Ctrl+C to stop${n:-}"
tick=0; last_lines=-1
if [ "${ONESHOT:-}" = "1" ]; then assess 1; exit 0; fi
while [ ! -f "$RUNDIR/logs/.stop" ]; do
  cur_lines="$(wc -l < "$RUNDIR/logs/tools.jsonl" 2>/dev/null | tr -d ' ')"; cur_lines="${cur_lines:-0}"
  if [ "$cur_lines" != "$last_lines" ]; then
    tick=$((tick+1)); assess "$tick"; last_lines="$cur_lines"
  else
    echo "${d:-}[auditor] no new tool activity — holding (tick skipped, saves tokens)${n:-}"
  fi
  sleep "$INTERVAL"
done
