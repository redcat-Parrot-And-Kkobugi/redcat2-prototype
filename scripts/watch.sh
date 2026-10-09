#!/usr/bin/env bash
# =============================================================================
#  watch.sh [<name|ip|rundir>] — live feed of EVERYTHING the hunt does, in a 2nd terminal.
#  Interleaves two streams in real time:
#    - the agent's own reasoning (text + thinking) from logs/conv.jsonl
#    - every tool call the instant it starts (▶ pre) and its full output when done (✔ post),
#      from logs/tools.jsonl (written by the force-logging hook)
#  No arg → newest run under runs/.
#
#    scripts/watch.sh                 # newest run
#    scripts/watch.sh Blizzard        # by machine name / slug
#    FULL=1 scripts/watch.sh          # print whole output per call (default: last 200 lines)
#    NOCONV=1 scripts/watch.sh        # tool feed only (no reasoning)
#
#  Live progress bars (nmap --stats-every, hashcat, ffuf) animate only on the terminal the
#  command runs on — those run in the hunt's tmux session; attach it to watch them live:
#      tmux attach -t rc2_<slug>_main
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
arg="${1:-}"
MAX="${MAX:-200}"

if   [ -n "$arg" ] && [ -d "$arg" ];            then RUNDIR="$arg"
elif [ -n "$arg" ] && [ -d "$ROOT/runs/$arg" ]; then RUNDIR="$ROOT/runs/$arg"
else RUNDIR="$(ls -1dt "$ROOT"/runs/*/ 2>/dev/null | head -1)"; RUNDIR="${RUNDIR%/}"; fi
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "no run dir (pass a name/ip, or start a hunt first)"; exit 1; }

LOGS="$RUNDIR/logs"; jsonl="$LOGS/tools.jsonl"; conv="$LOGS/conv.jsonl"
slug="$(basename "$RUNDIR")"
cyan=$'\033[36m'; green=$'\033[32m'; yellow=$'\033[33m'; dim=$'\033[2m'; red=$'\033[31m'; rst=$'\033[0m'

echo "${dim}── watching $RUNDIR ──${rst}"
echo "${dim}live progress bars: tmux attach -t rc2_${slug}_main${rst}"
echo "${dim}memory: $RUNDIR/{worldmodel,hypotheses,journal}.md   (waiting for activity… Ctrl-C to stop)${rst}"

# agent reasoning (text/thinking) from conv.jsonl; --no-tools avoids duplicating the tool feed below.
CONV_PID=""
if [ "${NOCONV:-0}" != "1" ] && command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/scripts/conv_fmt.py" ]; then
  ( tail -F -n +1 "$conv" 2>/dev/null | python3 "$ROOT/scripts/conv_fmt.py" --no-tools ) &
  CONV_PID=$!
  trap '[ -n "$CONV_PID" ] && kill "$CONV_PID" 2>/dev/null' EXIT INT TERM
fi

for _ in $(seq 1 600); do [ -f "$jsonl" ] && break; sleep 1; done
[ -f "$jsonl" ] || { echo "no tool activity yet at $jsonl"; exit 0; }

tail -F -n +1 "$jsonl" 2>/dev/null | while IFS= read -r line; do
  ev="$(printf '%s' "$line"  | jq -r '.event // empty' 2>/dev/null)"; [ -n "$ev" ] || continue
  ts="$(printf '%s' "$line"  | jq -r '.ts // ""')"
  tool="$(printf '%s' "$line"| jq -r '.tool // "?"')"
  cmd="$(printf '%s' "$line" | jq -r '.command // (.input|tostring) // "" ' 2>/dev/null)"
  if [ "$ev" = "pre" ]; then
    printf '%s\xe2\x96\xb6 %s%s  [%s] %s%s%s\n' "$cyan" "$ts" "$rst" "$tool" "$yellow" "${cmd:-$tool}" "$rst"
  else
    ex="$(printf '%s' "$line" | jq -r '.exit // ""')"
    b="$(printf '%s' "$line"  | jq -r '.out_bytes // 0')"
    of="$(printf '%s' "$line" | jq -r '.out_file // ""')"
    col="$green"; [ "$ex" != "0" ] && [ -n "$ex" ] && col="$red"
    printf '%s\xe2\x9c\x93 %s  [%s]  exit=%s  %sB%s\n' "$col" "$ts" "$tool" "${ex:-?}" "$b" "$rst"
    if [ -n "$of" ] && [ -f "$LOGS/$of" ]; then
      if [ "${FULL:-0}" = "1" ]; then sed 's/^/    /' "$LOGS/$of"
      else tail -n "$MAX" "$LOGS/$of" | sed 's/^/    /'; fi
    fi
  fi
done
