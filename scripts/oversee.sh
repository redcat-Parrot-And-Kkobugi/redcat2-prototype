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
#    OVERSEE_MODEL=sonnet scripts/oversee.sh blizzard
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
unset ANTHROPIC_API_KEY
: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env}"
g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; c=$'\033[36m'; d=$'\033[2m'; n=$'\033[0m'

NAME="${1:?usage: oversee.sh <machine-name|run-slug> [\"operator directive\"]}"
OP_NOTE="${2:-${OP_NOTE:-}}"
RUNDIR="$ROOT/runs/$NAME"
[ -d "$RUNDIR" ] || { echo "${r}no run dir: $RUNDIR${n} (start the hunt first)"; exit 1; }
INTERVAL="${OVERSEE_INTERVAL:-600}"
MODEL="${OVERSEE_MODEL:-opus}"
SUP="$RUNDIR/supervisor.md"
HIST="$RUNDIR/logs/supervisor.jsonl"
SYS="$ROOT/OVERSEER.md"
mkdir -p "$RUNDIR/logs"

build_digest(){
  local tj="$RUNDIR/logs/tools.jsonl" elapsed="?" now; now=$(date +%s)
  [ -f "$RUNDIR/logs/meta.env" ] && { . "$RUNDIR/logs/meta.env" 2>/dev/null; [ -n "${start_epoch:-}" ] && elapsed="$(( (now-start_epoch)/60 ))m"; }
  . "$RUNDIR/target.env" 2>/dev/null || true

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

assess(){
  local rev="$1" digest verdict ts status cur new
  digest="$(build_digest)"
  ts="$(date '+%F %T')"
  echo "${c}[oversee]${n} review #$rev @ $ts (${MODEL}) ..."
  verdict="$(printf '%s\n' "$digest" | timeout 300 claude -p \
      "This is a hunt digest to review. Per the OVERSEER instructions: first judge whether the trajectory is progressing from the logs + living files, then Read 2-4 relevant screenshots from '## recent images' (images render natively), Read raw logs if needed, synthesize, and output ONLY the verdict in the specified format. Read-only tools only (Read/Glob/Grep).
---
$(cat)" \
      --model "$MODEL" --append-system-prompt "$(cat "$SYS")" \
      --allowedTools "Read Glob Grep" 2>&1)" || verdict="(reviewer call failed: $verdict)"
  status="$(printf '%s' "$verdict" | grep -oiE 'STATUS:[[:space:]]*(on-track|minor-drift|rabbit-hole)' | head -1 \
            | grep -oiE 'on-track|minor-drift|rabbit-hole' | tr 'A-Z' 'a-z')"; status="${status:-unknown}"

  jq -cn --arg ts "$ts" --arg rev "$rev" --arg st "$status" --arg v "$verdict" \
     '{ts:$ts, review:($rev|tonumber), status:$st, intervened:($st!="on-track"), verdict:$v}' >> "$HIST" 2>/dev/null

  if [ "$status" = "on-track" ]; then
    echo "${g}   on-track — no intervention (supervisor.md untouched)${n}"
    printf '%s\n' "$verdict" | grep -iE '^[[:space:]]*(STATUS|READ|GOOD):' | sed 's/^/   /'
    return 0
  fi
  cur="$(grep -oE '^SUPERVISOR_TICK: [0-9]+' "$SUP" 2>/dev/null | grep -oE '[0-9]+' | head -1)"; cur="${cur:-0}"; new=$((cur+1))
  { echo "SUPERVISOR_TICK: $new   ($ts · $status)"
    echo "# operator-level reviewer (auto). SOLVER: act ONLY when SUPERVISOR_TICK changed since you last followed it; then follow STOP / DO NEXT (operator priority, overrides your own 'dead end' conclusions). A new tick means: course-correct now."
    echo "_review #$rev · model=${MODEL}_"
    echo
    printf '%s\n' "$verdict"
  } > "$SUP"
  local tag="${y}minor-drift${n}"; [ "$status" = "rabbit-hole" ] && tag="${r}RABBIT-HOLE${n}"; [ "$status" = "unknown" ] && tag="${y}unknown→intervene${n}"
  echo "   ${tag} → wrote supervisor.md (SUPERVISOR_TICK $new)"
  printf '%s\n' "$verdict" | sed -n '1,14p' | sed 's/^/   /'
}

echo "${c}[oversee]${n} watching $RUNDIR  (model=$MODEL interval=${INTERVAL}s)"
echo "${d}   reviews on each new activity; writes $SUP ONLY on drift/rabbit-hole; every review → $HIST ; Ctrl+C to stop${n}"
[ -n "$OP_NOTE" ] && echo "${y}   operator directive active:${n} $OP_NOTE ${d}(relayed to solver until followed)${n}"
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
