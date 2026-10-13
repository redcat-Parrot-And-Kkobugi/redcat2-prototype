#!/usr/bin/env bash
# =============================================================================
#  scripts/oversee.sh <name|slug> ["operator directive"] — supervisor/critic loop.
#
#  Periodically reads a running hunt's logs + living files, has a reviewer model
#  (opus) judge progress vs. rabbit-hole, and writes:
#    runs/<slug>/supervisor.md         — latest verdict; the SOLVER reads & follows it
#    runs/<slug>/logs/supervisor.jsonl — full history (one JSON line per tick)
#  Run it in a 2nd terminal alongside ./hunt (like watch.sh). It never touches the
#  target — it only reads logs and writes advice.
#
#    scripts/oversee.sh blizzard                       # loop, default 600s
#    scripts/oversee.sh blizzard "focus the SSTI on /render, not the login"
#    OVERSEE_INTERVAL=300 scripts/oversee.sh blizzard
#    ONESHOT=1 scripts/oversee.sh blizzard             # one assessment then exit
#    OVERSEE_MODEL=claude-opus-4-8 scripts/oversee.sh blizzard   # pin reviewer model (default: 4.8)
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
unset ANTHROPIC_API_KEY
: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env}"
# relaunch/tick cache efficiency (this pane doesn't call rc2_load_env; mirror lib/env.sh's policy so the
# supervisor reuses its byte-stable prefix across ticks). OAuth above makes 1h eligible.
: "${CLAUDE_CODE_PROMPT_CACHE_TTL:=1h}"; : "${DISABLE_AUTOUPDATER:=1}"
export CLAUDE_CODE_PROMPT_CACHE_TTL DISABLE_AUTOUPDATER

usage(){ echo "usage: oversee.sh [-s|--slug <name>] [-m|--model <model>] [-d|--directive <text>] [-i|--interval <sec>] [--oneshot] [<slug> [directive]]" >&2; }
_slug="" _model="" _directive="" _interval="" _oneshot=""; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--slug)      [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage; exit 2; }; _slug="$2"; shift 2 ;;
    -m|--model)     [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage; exit 2; }; _model="$2"; shift 2 ;;
    -d|--directive) [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage; exit 2; }; _directive="$2"; shift 2 ;;
    -i|--interval)  [ $# -ge 2 ] || { echo "missing value for $1" >&2; usage; exit 2; }; _interval="$2"; shift 2 ;;
    --oneshot)      _oneshot=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
    -*)             echo "unknown option: $1" >&2; usage; exit 2 ;;
    *)              pos+=("$1"); shift ;;
  esac
done
# positional back-compat (hunt calls `oversee.sh '<slug>'`): pos[0]=slug, pos[1]=directive, only if the flag was not given
[ -z "$_slug" ] && [ "${#pos[@]}" -ge 1 ] && _slug="${pos[0]}"
[ -z "$_directive" ] && [ "${#pos[@]}" -ge 2 ] && _directive="${pos[1]}"
[ "${#pos[@]}" -gt 2 ] && echo "${y:-}warning: extra positional args ignored — pass model/directive as -m/-d (e.g. -m opus -d \"…\")${n:-}" >&2
# precedence: flag > env > default. Empty slug → newest run (so `-d "…"` alone works).
NAME="$_slug"
OP_NOTE="${_directive:-${OP_NOTE:-}}"
MODEL="${_model:-${OVERSEE_MODEL:-claude-opus-4-8}}"
INTERVAL="${_interval:-${OVERSEE_INTERVAL:-600}}"
[ -n "$_oneshot" ] && ONESHOT=1
RUNDIR="$(rc2_resolve_rundir "$NAME")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "${r}no run dir${NAME:+ for '$NAME'}${n} (pass -s <name>, or start a hunt first)"; exit 1; }
NAME="$(basename "$RUNDIR")"   # normalize to the resolved slug (used by the digest + pgrep)
SUP="$RUNDIR/supervisor.md"
HIST="$RUNDIR/logs/supervisor.jsonl"
SYS="$ROOT/OVERSEER.md"
mkdir -p "$RUNDIR/logs"

# P2 weighted gate (opt-in): escalate the LIVE guard mode only after GATE_N consecutive rabbit-hole
# verdicts about the SAME focus. On by RC2_GATE=1 or whenever an operator floor is set (RC2_GUARD!=off).
# R5 (intentional, not a bug): this predicate decides whether OVERSEE may move the LIVE tier. It is
# NOT the same as hunt's watcher predicate — hunt also honours RC2_GUARD_WATCH (judge-only, no gate).
# Here: the gate is on if the operator set any floor (RC2_GUARD!=off) or explicitly opted in (RC2_GATE=1).
GATE=0; rc2_guard_core_on && GATE=1   # core = floor(RC2_GUARD!=off) or RC2_GATE=1 (guard_lib; see note there)
GATE_N="${RC2_GATE_N:-2}"
GATE_MODE="${RC2_GATE_MODE:-block}"

build_digest(){
  local tj="$RUNDIR/logs/tools.jsonl" elapsed="?" now; now=$(date +%s)
  [ -f "$RUNDIR/logs/meta.env" ] && { . "$RUNDIR/logs/meta.env" 2>/dev/null; [ -n "${start_epoch:-}" ] && elapsed="$(( (now-start_epoch)/60 ))m"; }
  rc2_load_target "$RUNDIR" 2>/dev/null || true

  [ -n "${OP_NOTE:-}" ] && { echo "## OPERATOR DIRECTIVE (human — HIGHEST priority). Relay to the solver and keep nudging (not on-track) until it actually follows this:"; echo "  $OP_NOTE"; echo; }
  echo "# HUNT DIGEST"
  echo "machine=${machine_name:-$NAME} ip=${target_ip:-?} os=${os_hint:-?} difficulty=${difficulty:-?} elapsed=${elapsed}"
  echo "hunt_running=$(pgrep -f "hunt .*$NAME|claude -p .*$NAME" >/dev/null 2>&1 && echo yes || echo no)"
  echo
  echo "## flags.txt"; sed 's/^/  /' "$RUNDIR/flags.txt" 2>/dev/null
  echo
  echo "## heuristics"
  if [ -f "$tj" ]; then
    echo "  tool_calls(lines)=$(wc -l < "$tj" | tr -d ' ')"
    echo "  confirmed hypotheses=$(grep -ciE 'status:[[:space:]]*confirmed' "$RUNDIR/hypotheses.md" 2>/dev/null)  frozen/refuted=$(grep -ciE 'status:[[:space:]]*(frozen|refuted)' "$RUNDIR/hypotheses.md" 2>/dev/null)"
    echo "  top repeated bash command-stems (first 4 tokens):"
    jq -r 'select(.event=="pre" and .command!=null) | .command' "$tj" 2>/dev/null \
      | awk '{print $1, $2, $3, $4}' | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /'
    echo "  most-hit URLs/endpoints:"
    jq -r 'select(.event=="pre" and .command!=null) | .command' "$tj" 2>/dev/null \
      | grep -oE 'https?://[^ "'"'"']+' | sed -E 's#\?.*##' | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
    echo "  journal.md last changed: $(stat -c '%y' "$RUNDIR/journal.md" 2>/dev/null | cut -d. -f1) (now $(date '+%F %T'))"
  else echo "  (no tools.jsonl yet)"; fi
  echo
  echo "## worldmodel.md"; sed 's/^/  /' "$RUNDIR/worldmodel.md" 2>/dev/null | head -120
  echo
  echo "## hypotheses.md"; sed 's/^/  /' "$RUNDIR/hypotheses.md" 2>/dev/null | head -140
  echo
  echo "## journal.md (tail)"; tail -40 "$RUNDIR/journal.md" 2>/dev/null | sed 's/^/  /'
  echo
  echo "## trajectory — your prior verdicts (newest first; is the solver HEEDING your last DO NEXT + improving?)"
  if [ -s "$HIST" ]; then
    tail -3 "$HIST" | tac | jq -r '"  [#\(.review) \(.ts) \(.status)] " + ((.verdict|gsub("[\n]";" "))[0:280])' 2>/dev/null
  else echo "  (none yet — first review)"; fi
  echo
  echo "## recent images (Read the most relevant 2-4 to SEE what the solver sees — absolute paths)"
  find "$RUNDIR/loot" "$RUNDIR/enum" "$RUNDIR/exploit" "$RUNDIR/recon" "$RUNDIR/reversing" -maxdepth 5 -type f \
       \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \) -printf '%T@\t%s\t%p\n' 2>/dev/null \
    | sort -rn | head -10 | awk -F'\t' '{printf "  %s (%d B)\n", $3, $2}'
  echo "## last 60 tool calls (ts tool | command[:240])"
  if [ -f "$tj" ]; then
    jq -r 'select(.event=="pre") | [.ts, .tool, ((.command // (.input|tostring))[0:240])] | @tsv' "$tj" 2>/dev/null \
      | tail -60 | sed 's/^/  /'
  fi
}

# _oversee_review <model> — run one reviewer pass ($1=model, digest on stdin), verdict (or error text) on stdout.
_oversee_review(){
  timeout 300 claude -p \
      "This is a hunt digest to review. Per the OVERSEER instructions: first judge whether the trajectory is progressing from the logs + living files, then Read 2-4 relevant screenshots from '## recent images' (images render natively), Read raw logs if needed, synthesize, and output ONLY the verdict in the specified format. Read-only tools only (Read/Glob/Grep).
---
$(cat)" \
      --model "$1" --append-system-prompt "$(cat "$SYS")" \
      --allowedTools "Read Glob Grep" 2>&1
}
# _oversee_failed <rc> <verdict-text> — 0(true) if the review call failed (non-zero or an error signature).
_oversee_failed(){ [ "$1" -ne 0 ] && return 0; printf '%s' "$2" | grep -qiE 'API Error|safeguards flagged|\[cyber\]|Request ID|reviewer call failed'; }
_oversee_cyber(){ printf '%s' "$1" | grep -qiE 'safeguards flagged|\[cyber\]|Cyber Verification'; }

# _oversee_gate <status> <verdict> — the P2 weighted gate. Tracks consecutive rabbit-hole verdicts
# about the SAME FOCUS in accounting.json and, at GATE_N, raises the LIVE guard mode via guard.sh
# (re-asserted each tick); any on-track/minor-drift breaks the streak and releases the gate. Opt-in,
# never fires on error/unknown, and (by guard.sh) can never pull enforcement below the operator floor.
_oversee_gate(){
  local status="$1" verdict="$2" acct="$RUNDIR/logs/accounting.json"
  [ "${GATE:-0}" = "1" ] && [ -s "$acct" ] || return 0
  case "$status" in rabbit-hole|on-track|minor-drift) ;; *) return 0 ;; esac
  local focus fp prev_fp streak gated
  focus="$(printf '%s' "$verdict" | grep -oiE '^FOCUS:.*' | head -1 | sed -E 's/^[Ff][Oo][Cc][Uu][Ss]:[[:space:]]*//' | cut -c1-80)"
  fp="$(printf '%s' "$focus" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"; [ -n "$fp" ] || fp="unspecified"
  prev_fp="$(jq -r '.supervisor.last_fp // ""' "$acct" 2>/dev/null)"
  streak="$(jq -r '.supervisor.consecutive_rabbit_hole // 0' "$acct" 2>/dev/null)"
  gated="$(jq -r '.supervisor.gated // false' "$acct" 2>/dev/null)"

  if [ "$status" = "rabbit-hole" ]; then
    if [ "$fp" = "$prev_fp" ]; then streak=$((streak+1)); else streak=1; fi
    rc2_json_update "$acct" '.supervisor.consecutive_rabbit_hole=$s | .supervisor.last_fp=$fp | .supervisor.last_verdict="rabbit-hole"' --arg fp "$fp" --argjson s "$streak"
    if [ "$streak" -ge "${GATE_N:-2}" ]; then
      if "$ROOT/scripts/guard.sh" "$RUNDIR" "${GATE_MODE:-block}" "rabbit-hole consensus x$streak: $focus" >/dev/null 2>&1; then
        rc2_json_update "$acct" '.supervisor.gated=true'
        echo "   ${r}GATE${n} live→${GATE_MODE:-block}  (rabbit-hole x$streak on '$focus')"
      fi
    else
      echo "   ${y}gate: rabbit-hole streak $streak/${GATE_N:-2} on '$focus' (needs $(( ${GATE_N:-2} - streak )) more to escalate)${n}"
    fi
  else
    if [ "$streak" -gt 0 ] || [ "$gated" = "true" ]; then
      rc2_json_update "$acct" '.supervisor.consecutive_rabbit_hole=0 | .supervisor.last_fp="" | .supervisor.gated=false | .supervisor.last_verdict=$st' --arg st "$status"
      if [ "$gated" = "true" ]; then
        "$ROOT/scripts/guard.sh" "$RUNDIR" off "back to $status — release gate" >/dev/null 2>&1 \
          && echo "   ${g}gate released (live→off; effective falls back to operator floor)${n}"
      fi
    fi
  fi
}

assess(){
  local rev="$1" digest verdict ts status cur new rc intervened
  digest="$(build_digest)"
  ts="$(date '+%F %T')"
  echo "${c}[oversee]${n} review #$rev @ $ts (${MODEL}) ..."
  verdict="$(printf '%s\n' "$digest" | _oversee_review "$MODEL")"; rc=$?

  # A content-based [cyber] safeguard re-trips on the same digest, so a fresh session won't clear it —
  # the lever is a less-restricted model. If OVERSEE_FALLBACK_MODEL is set, retry ONCE with it.
  if _oversee_failed "$rc" "$verdict" && _oversee_cyber "$verdict" && [ -n "${OVERSEE_FALLBACK_MODEL:-}" ]; then
    echo "${y}   [cyber] reviewer flagged — retrying once with OVERSEE_FALLBACK_MODEL=$OVERSEE_FALLBACK_MODEL${n}"
    verdict="$(printf '%s\n' "$digest" | _oversee_review "$OVERSEE_FALLBACK_MODEL")"; rc=$?
  fi

  if _oversee_failed "$rc" "$verdict"; then
    status="error"
  else
    status="$(printf '%s' "$verdict" | grep -oiE 'STATUS:[[:space:]]*(on-track|minor-drift|rabbit-hole)' | head -1 \
              | grep -oiE 'on-track|minor-drift|rabbit-hole' | tr 'A-Z' 'a-z')"; status="${status:-unknown}"
  fi
  intervened=false; { [ "$status" = "minor-drift" ] || [ "$status" = "rabbit-hole" ]; } && intervened=true

  jq -cn --arg ts "$ts" --arg rev "$rev" --arg st "$status" --arg v "$verdict" --argjson iv "$intervened" \
     '{ts:$ts, review:($rev|tonumber), status:$st, intervened:$iv, verdict:$v}' >> "$HIST" 2>/dev/null

  _oversee_gate "$status" "$verdict"   # P2: consensus-gated live-mode escalation (opt-in; no-op on error/unknown)

  if [ "$status" = "on-track" ]; then
    echo "${g}   on-track — no intervention (supervisor.md untouched)${n}"
    printf '%s\n' "$verdict" | grep -iE '^[[:space:]]*(STATUS|READ|GOOD):' | sed 's/^/   /'
    return 0
  fi
  # error / unknown → NEVER write a directive or bump the tick (the solver would then follow garbage).
  if [ "$intervened" != "true" ]; then
    if _oversee_cyber "$verdict"; then
      echo "${r}   [cyber] reviewer flagged by safeguards — supervisor.md + tick UNCHANGED.${n}"
      echo "${d}   (a fresh session won't clear a content-based flag; set OVERSEE_FALLBACK_MODEL=<less-restricted model> or apply to the Cyber Verification Program)${n}"
    elif [ "$status" = "error" ]; then
      echo "${y}   reviewer call failed — supervisor.md + tick UNCHANGED (logged as error).${n}"
    else
      echo "${y}   reviewer returned no parseable STATUS — supervisor.md + tick UNCHANGED.${n}"
    fi
    return 0
  fi

  new="$(rc2_write_supervisor "$RUNDIR" "$status" "$(printf '_review #%s · model=%s_\n\n%s' "$rev" "$MODEL" "$verdict")")"
  local tag="${y}minor-drift${n}"; [ "$status" = "rabbit-hole" ] && tag="${r}RABBIT-HOLE${n}"
  echo "   ${tag} → wrote supervisor.md (SUPERVISOR_TICK $new)"
  printf '%s\n' "$verdict" | sed -n '1,14p' | sed 's/^/   /'
}

echo "${c}[oversee]${n} watching $RUNDIR  (model=$MODEL interval=${INTERVAL}s)"
echo "${d}   reviews on each new activity; writes $SUP ONLY on drift/rabbit-hole; every review → $HIST ; Ctrl+C to stop${n}"
[ -n "$OP_NOTE" ] && echo "${y}   operator directive active:${n} $OP_NOTE ${d}(relayed to solver until followed)${n}"
if [ "$GATE" = "1" ]; then echo "${y}   weighted gate ON:${n} ${GATE_N} consecutive same-focus rabbit-holes → live guard '${GATE_MODE}' (re-asserted; never below operator floor)"
else echo "${d}   weighted gate off (advisory only; set RC2_GATE=1 or RC2_GUARD=warn|block to enable auto-escalation)${n}"; fi
tick=0; last_lines=-1
if [ "${ONESHOT:-}" = "1" ]; then assess 1; exit 0; fi
while true; do
  cur_lines="$(wc -l < "$RUNDIR/logs/tools.jsonl" 2>/dev/null | tr -d ' ')"; cur_lines="${cur_lines:-0}"
  if [ "$cur_lines" != "$last_lines" ]; then
    tick=$((tick+1)); assess "$tick"; last_lines="$cur_lines"
  else
    echo "${d}[oversee] no new tool activity — holding (tick skipped, saves tokens)${n}"
  fi
  sleep "$INTERVAL"
done
