#!/usr/bin/env bash
# =============================================================================
#  report.sh <rundir> — compute hunt metrics and inject them into writeup.md.
#  Retrospective: where the agent got stuck, how fast/slow, token spend, per-phase
#  breakdown — so the doctrine and sub-agent model split can be tuned over time.
#  Deterministic metrics from logs/tools.jsonl + logs/phases.log; token/cost are
#  best-effort from the session log. Auto-run by hunt on exit; safe standalone.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/tools_log.sh"
RUNDIR="$(rc2_resolve_rundir "${1:?usage: report.sh <rundir|name|ip>}")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "report: no run dir"; exit 0; }
LOGS="$RUNDIR/logs"; J="$LOGS/tools.jsonl"
# shellcheck source=/dev/null
rc2_load_target "$RUNDIR"
# shellcheck source=/dev/null
[ -f "$LOGS/meta.env" ] && . "$LOGS/meta.env"   # model, start_epoch

now=$(date +%s); start="${start_epoch:-$now}"; wall=$(( now - start ))
fmt(){ local s=$1; printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60)); }

# ── tool-call metrics ───────────────────────────────────────────────────────────
calls=$(rc2_tl_count "$J"); bash_calls=$(rc2_tl_count "$J" Bash); task_calls=$(rc2_tl_count "$J" Agent)   # delegations log as tool "Agent", not "Task"
dur_ms=$(rc2_tl_dur_ms "$J"); first_ts=$(rc2_tl_first_ts "$J"); last_ts=$(rc2_tl_last_ts "$J")
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
| sub-agent delegations (Agent) | ${task_calls:-0} |
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

# ── narrative writeup (auto from worldmodel.md + journal.md) ─────────────────────
# Assembled with printf/sed (NOT an unquoted heredoc) so file content is never shell-evaluated.
# Style: emoji banner by default (WRITEUP_EMOJI=1); set WRITEUP_EMOJI=0 for a plain ASCII fallback.
# _build_writeup_narrative — emit the auto writeup narrative (worldmodel + journal) on stdout.
# Uses RUNDIR + the target.env fields (machine_name/target_ip/os_hint/difficulty) from the outer scope.
_build_writeup_narrative() {
  local WM="$RUNDIR/worldmodel.md" JO="$RUNDIR/journal.md" uf rf emoji fF fM fU fR chain tools_written
  uf="$(rc2_flag_value user "$RUNDIR")"; rf="$(rc2_flag_value root "$RUNDIR")"
  emoji="${WRITEUP_EMOJI:-1}"
  if [ "$emoji" = "1" ]; then fF='🏴 '; fM='🖥️'; fU='👤'; fR='🔑'; else fF=''; fM='•'; fU='•'; fR='•'; fi
  chain="$(awk -v e="$emoji" '
    /^[0-9]{4}-/{
      m="🔹"; if(e!="1")m="-";
      if(e=="1"){ if($0~/FOOTHOLD/)m="🎯"; else if($0~/USER/)m="👤"; else if($0~/ROOT/)m="🧗"; else if($0~/PIVOT/)m="🔀"; else if($0~/START/)m="🧭"; }
      print "- " m " " $0;
    }' "$JO" 2>/dev/null | head -30)"
  tools_written="$(cd "$RUNDIR" 2>/dev/null && find tools exploit -maxdepth 2 -type f 2>/dev/null | sed 's#^#- #' | head -40)"
  printf '%s\n' "<!-- WRITEUP:START (auto by report.sh from worldmodel.md + journal.md — curated prose ABOVE this block is preserved) -->"
  printf '# %s%s — %s\n\n' "$fF" "${machine_name:-?}" "${target_ip:-?}"
  printf -- '- %s %s · difficulty %s\n'       "$fM" "${os_hint:-?}" "${difficulty:-?}"
  printf -- '- %s user.txt: `%s`\n'           "$fU" "${uf:-<not captured>}"
  printf -- '- %s root.txt: `%s`\n\n'         "$fR" "${rf:-<not captured>}"
  printf '## Solve chain\n'
  if [ -n "$chain" ]; then printf '%s\n' "$chain"; else printf '%s\n' "_(no milestones in journal.md)_"; fi
  printf '\n## Verified facts (from worldmodel.md)\n'
  if [ -s "$WM" ]; then sed '1{/^# /d;}' "$WM"; else printf '%s\n' "_(worldmodel.md empty)_"; fi
  printf '\n## Tools & exploits written\n'
  if [ -n "$tools_written" ]; then printf '%s\n' "$tools_written"; else printf '%s\n' "_(none)_"; fi
  printf '%s\n' "<!-- WRITEUP:END -->"
}

nf="$(mktemp)"; _build_writeup_narrative > "$nf"

WU="$RUNDIR/writeup.md"; touch "$WU"
# refresh/insert the narrative block (file-based splice → safe for any content)
if grep -q 'WRITEUP:START' "$WU" 2>/dev/null; then
  awk -v f="$nf" '/WRITEUP:START/{while((getline l < f)>0)print l; close(f); skip=1} /WRITEUP:END/{skip=0;next} !skip{print}' "$WU" > "$WU.tmp" && mv "$WU.tmp" "$WU"
else
  { cat "$nf"; echo; cat "$WU"; } > "$WU.tmp" && mv "$WU.tmp" "$WU"
fi
rm -f "$nf"
# refresh/insert the metrics block
if grep -q 'METRICS:START' "$WU" 2>/dev/null; then
  awk -v blk="$block" '/METRICS:START/{print blk;skip=1} /METRICS:END/{skip=0;next} !skip{print}' "$WU" > "$WU.tmp" && mv "$WU.tmp" "$WU"
else
  printf '\n%s\n' "$block" >> "$WU"
fi
echo "[report] writeup (narrative + metrics) written to $WU"
