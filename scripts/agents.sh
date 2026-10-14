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
#    scripts/agents.sh -n 20           # only the last 20 entries (snapshot); TAIL=20 also works
#    FULL=1 scripts/agents.sh          # each sub-agent's FULL result (default: truncated to SNIP chars)
#    SNIP=400 scripts/agents.sh        # truncation width for long sub-agent results (default 1200)
#    ONLY=oversee|auditor|agents ...   # restrict to one source
#  ANSI colour is stripped automatically when output is piped/redirected.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
[ -t 1 ] || { c=""; g=""; y=""; r=""; d=""; n=""; }   # no colour when piped/redirected

FOLLOW=0; POLL="${POLL:-5}"; TAIL="${TAIL:-0}"; SNIP="${SNIP:-1200}"; ONLY="${ONLY:-all}"; arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--follow) FOLLOW=1; shift ;;
    -n|--tail)   TAIL="${2:-0}"; shift 2 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *)           arg="$1"; shift ;;
  esac
done

RUNDIR="$(rc2_resolve_rundir "$arg")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "${r}no run dir${arg:+ for '$arg'}${n} (pass a name/ip, or start a hunt first)"; exit 1; }
LOGS="$RUNDIR/logs"; SUP="$LOGS/supervisor.jsonl"; AUD="$LOGS/auditor.jsonl"; TJ="$LOGS/tools.jsonl"; CONV="$LOGS/conv.jsonl"

_ep_clock(){ date -d "$1" +%s 2>/dev/null || echo 0; }                   # "YYYY-MM-DD HH:MM:SS" -> epoch
_emit(){ printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | base64 -w0)"; }    # <epoch> <block> -> one sortable row (raw bytes; NO escape interpretation)
# _clip <text> — truncate to $SNIP chars (unless FULL=1) with a tail hint. Keeps arbitrary bytes intact.
_clip(){ local t="$1" len=${#1}; if [ "${FULL:-0}" != 1 ] && [ "$len" -gt "$SNIP" ]; then printf '%s\n  … (+%s more chars — FULL=1 for the whole response)' "${t:0:$SNIP}" "$((len-SNIP))"; else printf '%s' "$t"; fi; }

# rows — every agent response as "<epoch>\t<base64 block>". Blocks are assembled with printf FORMAT
# newlines (so embedded backslashes/\n/\t in the text are NEVER re-interpreted). Unsorted; caller sorts.
rows(){
  local block
  # ── oversee verdicts ──
  if { [ "$ONLY" = all ] || [ "$ONLY" = oversee ]; } && [ -s "$SUP" ]; then
    while IFS=$'\t' read -r ts st rev vb; do
      printf -v block '%s[%s] oversee #%s — %s%s\n%s\n' "$c" "$ts" "$rev" "$st" "$n" "$(printf '%s' "$vb" | base64 -d 2>/dev/null)"
      _emit "$(_ep_clock "$ts")" "$block"
    done < <(jq -rc '[.ts, (.status//"?"), ((.review//0)|tostring), (.verdict|@base64)] | @tsv' "$SUP" 2>/dev/null)
  fi
  # ── auditor findings ──
  if { [ "$ONLY" = all ] || [ "$ONLY" = auditor ]; } && [ -s "$AUD" ]; then
    while IFS=$'\t' read -r ts au cl rev vb; do
      printf -v block '%s[%s] auditor #%s — %s/%s%s\n%s\n' "$y" "$ts" "$rev" "$au" "$cl" "$n" "$(printf '%s' "$vb" | base64 -d 2>/dev/null)"
      _emit "$(_ep_clock "$ts")" "$block"
    done < <(jq -rc '[.ts, (.audit//"?"), (.class//"-"), ((.review//0)|tostring), (.verdict|@base64)] | @tsv' "$AUD" 2>/dev/null)
  fi
  # ── sub-agent delegations + results ──
  if { [ "$ONLY" = all ] || [ "$ONLY" = agents ]; } && [ -s "$TJ" ]; then
    local -a pres posts; local i line ts sub desc prompt ack aid st sum outf result
    mapfile -t pres  < <(grep '"event":"pre"'  "$TJ" 2>/dev/null | grep '"tool":"Agent"')
    mapfile -t posts < <(grep '"event":"post"' "$TJ" 2>/dev/null | grep '"tool":"Agent"')
    [ "${#pres[@]}" -gt 0 ] || return 0
    i=0
    for line in "${pres[@]}"; do
      ts="$(printf '%s' "$line"     | jq -r '.ts // ""' 2>/dev/null)"
      sub="$(printf '%s' "$line"    | jq -r '.input.subagent_type // .input.subagentType // "agent"' 2>/dev/null)"
      desc="$(printf '%s' "$line"   | jq -r '.input.description // ""' 2>/dev/null)"
      prompt="$(printf '%s' "$line" | jq -r '(.input.prompt // "")[0:200]' 2>/dev/null)"
      ack="$(printf '%s' "${posts[$i]:-}" | jq -r '.out_file // ""' 2>/dev/null)"; i=$((i+1))
      aid=""; [ -n "$ack" ] && [ -f "$LOGS/$ack" ] && aid="$(jq -r '.agentId // ""' "$LOGS/$ack" 2>/dev/null)"
      st=""; sum=""; outf=""
      if [ -n "$aid" ] && [ -s "$CONV" ]; then
        IFS=$'\t' read -r st sum outf < <(jq -rc --arg a "$aid" 'select(.subtype=="task_notification" and .task_id==$a) | [(.status//"?"),(.summary//""),(.output_file//"")] | @tsv' "$CONV" 2>/dev/null | tail -1)
      fi
      # body: delegation + ask + the RESULT. Never leave the result silently blank — say what we have.
      if [ -n "$sum" ]; then result="${g}✓ ${st:-completed}${n} — $(_clip "$sum")"
      elif [ -n "$outf" ] && [ -f "$outf" ]; then result="${g}✓ ${st:-completed}${n} — $(_clip "$(cat "$outf" 2>/dev/null)")"
      elif [ -n "$aid" ]; then result="${d}… launched (agentId ${aid}); result not captured in the logs (still running, or the run ended first)${n}"
      else result="${d}… delegated; no result record found in the logs yet${n}"; fi
      printf -v block '%s[%s] → %s%s  "%s"%s\n  ask: %s\n  %s\n' "$g" "$ts" "$sub" "$n" "$desc" "" "${prompt:-(see logs)}" "$result"
      _emit "$(rc2_to_epoch "$ts")" "$block"
    done
  fi
}

# print_new <min_epoch> [tail_n] — decode+print rows with epoch > min, in time order; advance global HI.
HI=0
print_new(){
  local min="$1" lim="${2:-0}" e b
  while IFS=$'\t' read -r e b; do
    [ "${e:-0}" -gt "$min" ] 2>/dev/null || continue
    printf '%s\n' "$(printf '%s' "$b" | base64 -d 2>/dev/null)"
    [ "${e:-0}" -gt "$HI" ] 2>/dev/null && HI="$e"
  done < <(rows | sort -n | { [ "$lim" -gt 0 ] 2>/dev/null && tail -n "$lim" || cat; })
}

echo "${d}── agent responses for $RUNDIR ──  oversee + auditor + sub-agents (not the solver; use watch.sh for that)${n}"
_note=""; [ "$ONLY" != all ] && _note="source=$ONLY"; [ "$TAIL" -gt 0 ] 2>/dev/null && _note="${_note:+$_note, }last $TAIL"
[ -n "$_note" ] && echo "${d}   ($_note)${n}"
HI="0"; print_new 0 "$TAIL"; seen="$HI"
if [ "$FOLLOW" = 1 ]; then
  echo "${d}── following (poll ${POLL}s; Ctrl+C to stop) ──${n}"
  while [ ! -f "$LOGS/.stop" ]; do
    sleep "$POLL"
    print_new "$seen"; seen="$HI"
  done
fi
