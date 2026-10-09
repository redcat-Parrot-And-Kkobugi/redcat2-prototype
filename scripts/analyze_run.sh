#!/usr/bin/env bash
# =============================================================================
#  analyze_run.sh <rundir|name|ip> — Failure Analyzer.
#
#  Complements report.sh (SOLVE METRICS). This classifies WHY a run went the way it
#  did, from force-logged data (logs/tools.jsonl, logs/conv.jsonl, the .cmd_results
#  guard file) + the living files (hypotheses.md / journal.md / worldmodel.md /
#  phases.log / flags.txt), into a failure taxonomy — deterministic over logs.
#
#  Categories:
#    tool_execution   timeouts / non-zero exits
#    state_mgmt       same command/result repeated (re-ran a known result)
#    planning         long stretch, no confirmed hypothesis (no goal progress)
#    hypothesis       many frozen/refuted hypotheses (assumptions churned)
#    idle_wait        content-free "waiting/holding" turns (progress anti-pattern)
#    observation      big outputs with no follow-up win (weak proxy)
#
#  Writes: <rundir>/failure_analysis.json + .md. Always exits 0. Auto-run on exit.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

arg="${1:-}"
if   [ -n "$arg" ] && [ -d "$arg" ];            then RUNDIR="$arg"
elif [ -n "$arg" ] && [ -d "$ROOT/runs/$arg" ]; then RUNDIR="$ROOT/runs/$arg"
else RUNDIR="$(ls -1dt "$ROOT"/runs/*/ 2>/dev/null | head -1)"; RUNDIR="${RUNDIR%/}"; fi
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "analyze_run: no run dir"; exit 0; }

L="$RUNDIR/logs"; J="$L/tools.jsonl"; CONV="$L/conv.jsonl"
slug="$(basename "$RUNDIR")"
have_jq() { command -v jq >/dev/null 2>&1; }

diff="unknown"
[ -f "$RUNDIR/target.env" ] && diff="$(. "$RUNDIR/target.env" 2>/dev/null; echo "${difficulty:-unknown}")"
[ -n "$diff" ] || diff="unknown"

# ── outcome from flags.txt ───────────────────────────────────────────────────
u=0 r=0
[ -f "$RUNDIR/flags.txt" ] && { grep -qiE '^user=[0-9a-f]{32}' "$RUNDIR/flags.txt" && u=1; grep -qiE '^root=[0-9a-f]{32}' "$RUNDIR/flags.txt" && r=1; }
if [ "$u" = 1 ] && [ "$r" = 1 ]; then outcome="solved"; elif [ "$u" = 1 ] || [ "$r" = 1 ]; then outcome="partial"; else outcome="failed"; fi

# ── tool-call signals ────────────────────────────────────────────────────────
steps=0 errors=0 timeouts=0 bigout=0 repeated_actions=0 max_repeat=0 first_ts="" last_ts=""
if have_jq && [ -f "$J" ]; then
  steps="$(jq -r 'select(.event=="pre")|1' "$J" 2>/dev/null | wc -l | tr -d ' ')"
  errors="$(jq -r 'select(.event=="post" and (.exit!=null) and (.exit!=0))|1' "$J" 2>/dev/null | wc -l | tr -d ' ')"
  timeouts="$(jq -r 'select(.event=="post" and (.exit==124))|1' "$J" 2>/dev/null | wc -l | tr -d ' ')"
  bigout="$(jq -r 'select(.event=="post" and (.out_bytes>20000))|1' "$J" 2>/dev/null | wc -l | tr -d ' ')"
  first_ts="$(jq -r 'select(.event=="pre")|.ts' "$J" 2>/dev/null | head -1)"
  last_ts="$(jq -r '.ts' "$J" 2>/dev/null | tail -1)"
  repline="$(jq -r 'select(.event=="pre" and (.command!=null)) | (.command | gsub("[ \t\r\n]+";" ") | gsub("^ +| +$";""))' "$J" 2>/dev/null \
            | sort | uniq -c | sort -rn)"
  repeated_actions="$(printf '%s\n' "$repline" | awk '$1>=3{c++} END{print c+0}')"
  max_repeat="$(printf '%s\n' "$repline" | awk 'NR==1{print $1+0}')"
fi

# ── identical-result stalls (guard file: "<cmdhash> <resulthash> <consec>") ──
stalls=0
[ -f "$L/.cmd_results" ] && stalls="$(awk '$3+0>=2{c++} END{print c+0}' "$L/.cmd_results" 2>/dev/null)"

# ── idle-wait turns (conv.jsonl if present, else session log) ────────────────
idle_wait=0
WAITRE='waiting for|holding|hold on|will (continue|pick up|check).*(notif|monitor|callback)|stop polling|기다리|대기'
if have_jq && [ -f "$CONV" ]; then
  idle_wait="$(jq -rc 'select(.type=="assistant")|.message.content' "$CONV" 2>/dev/null \
    | jq -rc 'select((map(.type)|index("tool_use"))|not)|(map(select(.type=="text").text)|join(" "))' 2>/dev/null \
    | grep -ciE "$WAITRE" 2>/dev/null)"
else
  SL="$(ls -1t "$L"/session_*.log 2>/dev/null | head -1)"
  [ -n "$SL" ] && idle_wait="$(grep -ciE "$WAITRE" "$SL" 2>/dev/null)"
fi
idle_wait="${idle_wait:-0}"

# ── living-file signals (redcat2 memory) ─────────────────────────────────────
# wins = confirmed hypotheses; dead_ends = frozen/refuted hypotheses; last_win = journal tail
wins=0;      [ -f "$RUNDIR/hypotheses.md" ] && wins="$(grep -ciE 'status:[[:space:]]*confirmed' "$RUNDIR/hypotheses.md" 2>/dev/null)"
dead_ends=0; [ -f "$RUNDIR/hypotheses.md" ] && dead_ends="$(grep -ciE 'status:[[:space:]]*(frozen|refuted)' "$RUNDIR/hypotheses.md" 2>/dev/null)"
phases=0;    [ -f "$L/phases.log" ] && phases="$(wc -l < "$L/phases.log" 2>/dev/null | tr -d ' ')"
last_win="$(grep -vE '^\s*$' "$RUNDIR/journal.md" 2>/dev/null | tail -1 | cut -c1-120)"

# ── duration ─────────────────────────────────────────────────────────────────
to_epoch(){ local t="${1%%.*}"; local d="${t%T*}" c="${t#*T}"
  date -d "${d:0:4}-${d:4:2}-${d:6:2} ${c:0:2}:${c:2:2}:${c:4:2}" +%s 2>/dev/null || echo 0; }
dur_min=0
if [ -n "$first_ts" ] && [ -n "$last_ts" ]; then
  s=$(to_epoch "$first_ts"); e=$(to_epoch "$last_ts"); [ "$e" -ge "$s" ] 2>/dev/null && dur_min=$(( (e-s)/60 ))
fi

# ── scoring → primary category ───────────────────────────────────────────────
declare -A sc
err_rate=0; [ "${steps:-0}" -gt 0 ] 2>/dev/null && err_rate=$(( errors*100/steps ))
sc[tool_execution]=$(( timeouts*3 + (err_rate>15?3:0) + (errors>10?2:0) ))
sc[state_mgmt]=$(( repeated_actions*2 + stalls*3 + (max_repeat>=5?2:0) ))
sc[idle_wait]=$(( idle_wait*2 ))
sc[planning]=$(( (wins==0?3:0) + (steps>80 && wins<3 ? 3:0) + (phases<3?1:0) ))
sc[hypothesis]=$(( (dead_ends>6?2:0) + (dead_ends>12?2:0) ))
sc[observation]=$(( (bigout>5 && wins<2 ? 2:0) ))

primary="none"; best=0
for k in tool_execution state_mgmt idle_wait planning hypothesis observation; do
  v=${sc[$k]:-0}; if [ "$v" -gt "$best" ]; then best=$v; primary=$k; fi
done
[ "$outcome" = "solved" ] && primary="none"

# ── write JSON ───────────────────────────────────────────────────────────────
JSON="$RUNDIR/failure_analysis.json"
cat > "$JSON" <<EOF
{
  "run_id": "$slug",
  "difficulty": "$diff",
  "outcome": "$outcome",
  "steps": ${steps:-0},
  "duration_min": ${dur_min:-0},
  "failure_analysis": {
    "primary_category": "$primary",
    "tool_errors": ${errors:-0},
    "error_rate_pct": ${err_rate:-0},
    "timeouts": ${timeouts:-0},
    "repeated_actions": ${repeated_actions:-0},
    "max_repeat": ${max_repeat:-0},
    "identical_result_stalls": ${stalls:-0},
    "idle_wait_turns": ${idle_wait:-0},
    "confirmed_hypotheses": ${wins:-0},
    "frozen_refuted_hypotheses": ${dead_ends:-0},
    "phase_transitions": ${phases:-0},
    "big_outputs": ${bigout:-0}
  },
  "category_scores": {
    "tool_execution": ${sc[tool_execution]}, "state_mgmt": ${sc[state_mgmt]},
    "idle_wait": ${sc[idle_wait]}, "planning": ${sc[planning]},
    "hypothesis": ${sc[hypothesis]}, "observation": ${sc[observation]}
  }
}
EOF

# ── write markdown ───────────────────────────────────────────────────────────
MD="$RUNDIR/failure_analysis.md"
{
  echo "# failure analysis — $slug"
  echo "_outcome **$outcome** · difficulty $diff · $steps steps · ${dur_min}m · $(date -u +%FT%TZ)_"
  echo
  if [ "$outcome" = "solved" ]; then
    echo "✅ Solved — no failure classification."
  else
    echo "## primary suspected failure: \`$primary\`"; echo
  fi
  echo "## signals"
  echo "| signal | value | category |"
  echo "|---|---:|---|"
  echo "| tool errors / rate | ${errors} / ${err_rate}% | tool_execution |"
  echo "| timeouts (exit 124) | ${timeouts} | tool_execution |"
  echo "| repeated commands (≥3×) | ${repeated_actions} (max ${max_repeat}×) | state_mgmt |"
  echo "| identical cmd+result stalls | ${stalls} | state_mgmt |"
  echo "| idle 'waiting/holding' turns | ${idle_wait} | idle_wait |"
  echo "| confirmed hypotheses | ${wins} | planning |"
  echo "| phase transitions | ${phases} | planning |"
  echo "| frozen/refuted hypotheses | ${dead_ends} | hypothesis |"
  echo "| big outputs >20KB | ${bigout} | observation |"
  echo "| last journal line | ${last_win:-–} | |"
  echo
  echo "## category scores"
  for k in tool_execution state_mgmt idle_wait planning hypothesis observation; do
    printf -- "- %-16s %s\n" "$k" "${sc[$k]}"
  done
  echo
  if [ "${repeated_actions:-0}" -gt 0 ] 2>/dev/null && [ -n "${repline:-}" ]; then
    echo "## most-repeated commands (≥3×) — likely re-runs of known results"
    printf '%s\n' "$repline" | awk '$1>=3{n=$1; $1=""; sub(/^ +/,""); c=substr($0,1,140); print "- " n "x  `" c "`"}' | head -8
    echo
  fi
  echo "_signals are deterministic heuristics over logs — a pointer to where to look, not a verdict._"
} > "$MD"

echo "[analyze] $slug → $outcome, primary=$primary (steps=$steps, errs=$errors, repeat=$repeated_actions, stalls=$stalls, idle=$idle_wait, confirmed=$wins) → failure_analysis.md/.json"
exit 0
