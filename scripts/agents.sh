#!/usr/bin/env bash
# =============================================================================
#  agents.sh [<name|ip|rundir>] — one merged feed of everything the NON-solver agents say.
#  Unlike watch.sh (the solver's own reasoning + every tool call/result), this shows ONLY the
#  responses of the helper agents, in one chronological stream:
#    • oversee   — supervisor verdicts        (logs/supervisor.jsonl)
#    • auditor   — conclusiveness findings     (logs/auditor.jsonl)
#    • sub-agents— researcher/exploit-dev/verifier/... delegations + their result
#                  (logs/tools.jsonl `Agent` events, enriched from logs/conv.jsonl task notifications)
#  Read-only; it runs no model and never touches the target. A thin reader over the hook's logs.
#
#    scripts/agents.sh                 # newest run — snapshot of all agent responses so far
#    scripts/agents.sh Nimbus          # by machine name / slug
#    scripts/agents.sh -f              # follow live (poll; new responses as they land)
#    FULL=1 scripts/agents.sh          # include each sub-agent's FULL result (not just the summary)
#    ONLY=oversee|auditor|agents scripts/agents.sh   # restrict to one source
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"

FOLLOW=0; POLL="${POLL:-5}"; arg=""
for a in "$@"; do case "$a" in -f|--follow) FOLLOW=1 ;; -h|--help) sed -n '2,20p' "$0"; exit 0 ;; *) arg="$a" ;; esac; done
ONLY="${ONLY:-all}"

RUNDIR="$(rc2_resolve_rundir "$arg")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "${r:-}no run dir${arg:+ for '$arg'}${n:-} (pass a name/ip, or start a hunt first)"; exit 1; }
LOGS="$RUNDIR/logs"; SUP="$LOGS/supervisor.jsonl"; AUD="$LOGS/auditor.jsonl"; TJ="$LOGS/tools.jsonl"; CONV="$LOGS/conv.jsonl"
slug="$(basename "$RUNDIR")"

_ep_clock(){ date -d "$1" +%s 2>/dev/null || echo 0; }          # "YYYY-MM-DD HH:MM:SS" -> epoch
_emit(){ printf '%s\t%s\n' "$1" "$(printf '%b' "$2" | base64 -w0)"; }   # <epoch> <block(\n-escaped)> -> sortable row

# rows — every agent response as "<epoch>\t<base64 block>" lines (unsorted; the caller sorts + decodes).
rows(){
  # ── oversee verdicts ──
  if [ "$ONLY" = all ] || [ "$ONLY" = oversee ]; then [ -s "$SUP" ] && \
    jq -rc '[.ts, (.status//"?"), ((.review//0)|tostring), (.verdict|@base64)] | @tsv' "$SUP" 2>/dev/null \
    | while IFS=$'\t' read -r ts st rev vb; do
        _emit "$(_ep_clock "$ts")" "${c:-}[$ts] oversee #$rev — $st${n:-}\n$(printf '%s' "$vb" | base64 -d 2>/dev/null)\n"
      done; fi
  # ── auditor findings ──
  if [ "$ONLY" = all ] || [ "$ONLY" = auditor ]; then [ -s "$AUD" ] && \
    jq -rc '[.ts, (.audit//"?"), (.class//"-"), ((.review//0)|tostring), (.verdict|@base64)] | @tsv' "$AUD" 2>/dev/null \
    | while IFS=$'\t' read -r ts au cl rev vb; do
        _emit "$(_ep_clock "$ts")" "${y:-}[$ts] auditor #$rev — $au/$cl${n:-}\n$(printf '%s' "$vb" | base64 -d 2>/dev/null)\n"
      done; fi
  # ── sub-agent delegations + results (Agent events in tools.jsonl, completion from conv.jsonl) ──
  if { [ "$ONLY" = all ] || [ "$ONLY" = agents ]; } && [ -s "$TJ" ]; then
    # pair each Agent `pre` (sub/desc/prompt + ts) with the matching `post` (agentId in its ack file), by order.
    local pres posts i aid line ts sub desc prompt of notif
    mapfile -t pres  < <(grep '"event":"pre"'  "$TJ" | grep '"tool":"Agent"')
    mapfile -t posts < <(grep '"event":"post"' "$TJ" | grep '"tool":"Agent"')
    i=0
    for line in "${pres[@]}"; do
      ts="$(printf '%s' "$line"   | jq -r '.ts // ""' 2>/dev/null)"
      sub="$(printf '%s' "$line"  | jq -r '.input.subagent_type // .input.subagentType // "agent"' 2>/dev/null)"
      desc="$(printf '%s' "$line" | jq -r '.input.description // ""' 2>/dev/null)"
      prompt="$(printf '%s' "$line" | jq -r '(.input.prompt // "")[0:200]' 2>/dev/null)"
      of="${posts[$i]:-}"; i=$((i+1))
      aid="$(printf '%s' "$of" | jq -r '.out_file // ""' 2>/dev/null)"
      aid="$( [ -n "$aid" ] && [ -f "$LOGS/$aid" ] && jq -r '.agentId // ""' "$LOGS/$aid" 2>/dev/null || true)"
      # completion: match conv.jsonl task_notification by task_id == agentId -> status + summary + output_file
      local st="" sum="" outf=""
      if [ -n "$aid" ] && [ -s "$CONV" ]; then
        notif="$(jq -rc --arg a "$aid" 'select(.subtype=="task_notification" and .task_id==$a) | [(.status//"?"),(.summary//""),(.output_file//"")] | @tsv' "$CONV" 2>/dev/null | tail -1)"
        IFS=$'\t' read -r st sum outf <<<"$notif"
      fi
      local block="${g:-}[$ts] → ${sub}  \"${desc}\"${n:-}"
      [ -n "$prompt" ] && block="$block\n  ask: ${prompt}"
      [ -n "$st" ]     && block="$block\n  ${g:-}✓ ${st}${n:-}${sum:+ — $sum}"
      if [ "${FULL:-0}" = 1 ] && [ -n "$outf" ] && [ -f "$outf" ]; then
        block="$block\n  ----- full result -----\n$(sed 's/^/  /' "$outf" 2>/dev/null)\n  -----------------------"
      elif [ -n "$outf" ]; then
        block="$block\n  (full result: $outf — FULL=1 to inline)"
      fi
      _emit "$(rc2_to_epoch "$ts")" "$block\n"
    done
  fi
}

# print_new <min_epoch> — decode+print every row with epoch > min, in time order; set global HI to the
# highest epoch seen (process substitution keeps HI in this shell, so follow-mode can advance the marker).
HI=0
print_new(){
  local min="$1" e b; HI="$min"
  while IFS=$'\t' read -r e b; do
    [ "${e:-0}" -gt "$min" ] 2>/dev/null || continue
    printf '%s\n' "$(printf '%s' "$b" | base64 -d 2>/dev/null)"
    [ "${e:-0}" -gt "$HI" ] 2>/dev/null && HI="$e"
  done < <(rows | sort -n)
}

echo "${d:-}── agent responses for $RUNDIR ──  oversee + auditor + sub-agents (not the solver; use watch.sh for that)${n:-}"
[ "$ONLY" != all ] && echo "${d:-}   (filtered: ONLY=$ONLY)${n:-}"
print_new 0; seen="$HI"
if [ "$FOLLOW" = 1 ]; then
  echo "${d:-}── following (poll ${POLL}s; Ctrl+C to stop) ──${n:-}"
  while [ ! -f "$LOGS/.stop" ]; do
    sleep "$POLL"
    print_new "$seen"; seen="$HI"
  done
fi
