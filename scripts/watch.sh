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
#    REPLAY=1 scripts/watch.sh        # replay this run's FULL history first (default: live from now)
#
#  By default it shows only activity from the moment you attach — it does NOT dump the whole
#  accumulated log (which, after resumes/relaunches, can be thousands of lines). `REPLAY=1`
#  restores the old replay-from-start behavior. Each run's logs are per-run (runs/<slug>/logs);
#  the backlog you used to see was this one run's own history, not other machines'.
#
#  Live progress bars (nmap --stats-every, hashcat, ffuf) animate only on the terminal the
#  command runs on — those run in the hunt's tmux session; attach it to watch them live:
#      tmux attach -t rc2_<slug>_main
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
arg="${1:-}"
MAX="${MAX:-200}"
# live from now by default (-n 0); REPLAY=1 replays this run's full history (-n +1)
start="-n 0"; [ "${REPLAY:-0}" = "1" ] && start="-n +1"

RUNDIR="$(rc2_resolve_rundir "$arg")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "no run dir (pass a name/ip, or start a hunt first)"; exit 1; }

LOGS="$RUNDIR/logs"; jsonl="$LOGS/tools.jsonl"; conv="$LOGS/conv.jsonl"
slug="$(basename "$RUNDIR")"
cyan=$c green=$g yellow=$y dim=$d red=$r rst=$n   # keep local names, values from common.sh

echo "${dim}── watching $RUNDIR ──${rst}"
echo "${dim}live progress bars: tmux attach -t rc2_${slug}_main${rst}"
echo "${dim}memory: $RUNDIR/{worldmodel,hypotheses,journal}.md${rst}"
echo "${dim}$( [ "${REPLAY:-0}" = "1" ] && echo "replaying full history, then live" || echo "live from now (REPLAY=1 to replay full history)" )  ·  Ctrl-C to stop${rst}"

# agent reasoning (text/thinking) from conv.jsonl; --no-tools avoids duplicating the tool feed below.
CONV_PID=""
if [ "${NOCONV:-0}" != "1" ] && command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/scripts/conv_fmt.py" ]; then
  ( tail -F $start "$conv" 2>/dev/null | python3 "$ROOT/scripts/conv_fmt.py" --no-tools ) &
  CONV_PID=$!
  trap '[ -n "$CONV_PID" ] && kill "$CONV_PID" 2>/dev/null' EXIT INT TERM
fi

for _ in $(seq 1 600); do [ -f "$jsonl" ] && break; sleep 1; done
[ -f "$jsonl" ] || { echo "no tool activity yet at $jsonl"; exit 0; }

tail -F $start "$jsonl" 2>/dev/null | while IFS= read -r line; do
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
