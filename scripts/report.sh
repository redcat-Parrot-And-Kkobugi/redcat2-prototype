#!/usr/bin/env bash
# =============================================================================
#  report.sh <rundir> — compute hunt metrics and inject them into writeup.md.
#  Retrospective: where the agent got stuck, how fast/slow, token spend, per-phase
#  breakdown — so the doctrine and sub-agent model split can be tuned over time.
#  Deterministic metrics from logs/tools.jsonl + logs/phases.log; token/cost are
#  best-effort from the session log. Auto-run by hunt on exit; safe standalone.
# =============================================================================
set -uo pipefail
RUNDIR="${1:?usage: report.sh <rundir>}"
LOGS="$RUNDIR/logs"; J="$LOGS/tools.jsonl"
# shellcheck source=/dev/null
[ -f "$RUNDIR/target.env" ] && . "$RUNDIR/target.env"
# shellcheck source=/dev/null
[ -f "$LOGS/meta.env" ] && . "$LOGS/meta.env"   # model, start_epoch

now=$(date +%s); start="${start_epoch:-$now}"; wall=$(( now - start ))
fmt(){ local s=$1; printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60)); }

# ── tool-call metrics ───────────────────────────────────────────────────────────
calls=0 bash_calls=0 task_calls=0 dur_ms=0 first_ts="" last_ts=""
if [ -s "$J" ]; then
  calls=$(grep -c '"event":"post"' "$J" 2>/dev/null | head -1)
  bash_calls=$(grep '"event":"post"' "$J" 2>/dev/null | grep -c '"tool":"Bash"' | head -1)
  task_calls=$(grep '"event":"post"' "$J" 2>/dev/null | grep -c '"tool":"Task"' | head -1)
  dur_ms=$(grep '"event":"post"' "$J" 2>/dev/null | jq -s 'map(.duration_ms // 0)|add // 0' 2>/dev/null | head -1)
  first_ts=$(grep -m1 '"event":"pre"' "$J" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null | head -1)
  last_ts=$(grep '"event":"post"' "$J" 2>/dev/null | tail -1 | jq -r '.ts // empty' 2>/dev/null | head -1)
fi
calls=$(printf '%s' "${calls:-0}" | tr -dc '0-9'); calls=$((10#${calls:-0}))
bash_calls=$(printf '%s' "${bash_calls:-0}" | tr -dc '0-9'); bash_calls=$((10#${bash_calls:-0}))
task_calls=$(printf '%s' "${task_calls:-0}" | tr -dc '0-9'); task_calls=$((10#${task_calls:-0}))
dur_ms=$(printf '%s' "${dur_ms:-0}" | tr -dc '0-9'); dur_ms=$((10#${dur_ms:-0}))

# ── per-phase timing (agent appends "<iso> <phase>" to logs/phases.log) ─────────
phase_table=""
if [ -s "$LOGS/phases.log" ]; then
  prev_ep=""; prev_name=""
  while read -r pts pname; do
    [ -n "$pts" ] || continue
    ep=$(date -d "$pts" +%s 2>/dev/null) || ep=""
    if [ -n "$prev_ep" ] && [ -n "$ep" ]; then
      d=$((ep - prev_ep)); phase_table+="| ${prev_name:-?} | $((d/60))m$((d%60))s |"$'\n'
    fi
    prev_ep="$ep"; prev_name="$pname"
  done < "$LOGS/phases.log"
  if [ -n "$prev_ep" ]; then d=$((now - prev_ep)); [ "$d" -ge 0 ] && phase_table+="| ${prev_name:-?} (→now) | $((d/60))m$((d%60))s |"$'\n'; fi
fi

# ── token / cost (best-effort from the session log) ─────────────────────────────
tokens="N/A"; cost="N/A"
sess="$(ls -1t "$LOGS"/session_*.log 2>/dev/null | head -1)"
if [ -n "$sess" ]; then
  t=$(grep -oiE '[0-9,]+ *(input|output|total) tokens' "$sess" 2>/dev/null | tail -3 | paste -sd' ' -)
  [ -n "$t" ] && tokens="$t"
  c=$(grep -oiE '\$[0-9]+\.[0-9]+' "$sess" 2>/dev/null | tail -1)
  [ -n "$c" ] && cost="$c"
fi

flags="$(sed 's/^/  /' "$RUNDIR/flags.txt" 2>/dev/null)"
subs="$(sed 's/^/  /' "$LOGS/flag_submit.log" 2>/dev/null | tail -4)"

block="$(cat <<EOF
<!-- METRICS:START (auto by report.sh — do not edit between markers) -->
## Metrics

| metric | value |
|---|---|
| machine | ${machine_name:-?} (${os_hint:-?}, ${difficulty:-?}) |
| orchestrator model | ${model:-?} |
| total hunt time (wall) | $(fmt "$wall") |
| tool activity span | ${first_ts:-?} → ${last_ts:-?} |
| total tool calls | ${calls:-0} |
| shell commands | ${bash_calls:-0} |
| sub-agent delegations (Task) | ${task_calls:-0} |
| summed command time | $(( dur_ms / 1000 ))s |
| tokens (best-effort) | ${tokens} |
| cost (best-effort) | ${cost} |

### Per-phase
$( [ -n "$phase_table" ] && { echo "| phase | duration |"; echo "|---|---|"; echo "$phase_table"; } || echo "_no phases.log — have the agent append '<iso> <phase>' to logs/phases.log_" )

### Flags
\`\`\`
${flags:-  (none)}
\`\`\`
### Submissions
\`\`\`
${subs:-  (none)}
\`\`\`

> Retrospective: compare tool-call count, Task delegations, and per-phase time across runs to
> see where the agent spins (many commands, little progress) vs. solves cleanly; tune the
> doctrine and the sub-agent model split accordingly.
<!-- METRICS:END -->
EOF
)"

WU="$RUNDIR/writeup.md"; touch "$WU"
if grep -q 'METRICS:START' "$WU" 2>/dev/null; then
  awk -v blk="$block" '
    /METRICS:START/{print blk; skip=1}
    /METRICS:END/{skip=0; next}
    !skip{print}
  ' "$WU" > "$WU.tmp" && mv "$WU.tmp" "$WU"
else
  printf '\n%s\n' "$block" >> "$WU"
fi
echo "[report] metrics written to $WU"
