#!/usr/bin/env bash
# =============================================================================
#  scripts/lib/reviewer_loop.sh — shared scaffolding for the periodic LLM-reviewer
#  sidecars that watch a running hunt through its logs:
#    scripts/oversee.sh  — strategy critic   -> supervisor.md (+ weighted gate)
#    scripts/auditor.sh  — evidence-quality  -> auditor.md    (+ hook push)
#  Sourced by both, right after `set -uo pipefail`. Holds ONLY the boring,
#  must-stay-in-sync plumbing — env/cache policy, arg parsing, the cyber/err
#  verdict tests, the `claude -p` call wrapper, and the activity-gated main loop.
#  Each script keeps its OWN digest builder, assess body (parse + write), and any
#  gate logic (oversee's `_oversee_gate`). Design (a): share the skeleton, not the
#  behaviour. See docs/DEVELOPER.md §4.2.
# =============================================================================

# repo root resolved from THIS file (robust regardless of which sidecar sourced it)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; . "$ROOT/lib/common.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
unset ANTHROPIC_API_KEY
: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env}"
# relaunch/tick cache efficiency: a sidecar pane doesn't call rc2_load_env, so mirror lib/env.sh's policy
# here so it reuses its byte-stable prompt prefix across ticks. OAuth above makes the 1h TTL eligible.
: "${CLAUDE_CODE_PROMPT_CACHE_TTL:=1h}"; : "${DISABLE_AUTOUPDATER:=1}"
export CLAUDE_CODE_PROMPT_CACHE_TTL DISABLE_AUTOUPDATER

# rc2_reviewer_parse_args "$@" — set _slug/_model/_interval/_oneshot/_directive + pos[] from the common
# flags (-s/-m/-i/-d/--oneshot/-h/--). Callers apply their own precedence/defaults afterwards. `-d` is
# accepted for both sidecars (the auditor simply ignores _directive). An error/`-h` exits the sidecar.
rc2_reviewer_parse_args(){
  _slug="" _model="" _interval="" _oneshot="" _directive=""; pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--slug)      [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; _slug="$2"; shift 2 ;;
      -m|--model)     [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; _model="$2"; shift 2 ;;
      -i|--interval)  [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; _interval="$2"; shift 2 ;;
      -d|--directive) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; _directive="$2"; shift 2 ;;
      --oneshot)      _oneshot=1; shift ;;
      -h|--help)      echo "usage: $(basename "$0") [-s slug] [-m model] [-i sec] [-d directive] [--oneshot] [slug [directive]]" >&2; exit 0 ;;
      --)             shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*)             echo "unknown option: $1" >&2; exit 2 ;;
      *)              pos+=("$1"); shift ;;
    esac
  done
}

# rc2_reviewer_failed <rc> <verdict> — 0(true) if the review call failed (non-zero rc OR an error signature
# in the text — a content cyber flag, API error, or our own "reviewer call failed").
rc2_reviewer_failed(){ [ "$1" -ne 0 ] && return 0; printf '%s' "$2" | grep -qiE 'API Error|safeguards flagged|\[cyber\]|Request ID|reviewer call failed'; }
# rc2_reviewer_cyber <verdict> — 0(true) if a content cyber-safeguard flagged the review (a fresh session
# won't clear a content flag; the lever is a less-restricted *_FALLBACK_MODEL).
rc2_reviewer_cyber(){ printf '%s' "$1" | grep -qiE 'safeguards flagged|\[cyber\]|Cyber Verification'; }

# rc2_reviewer_call <model> <sysfile> <leadin> — one reviewer pass. Digest on stdin; verdict (or error
# text) on stdout. Read-only tools only; the sidecar never touches the target.
rc2_reviewer_call(){
  timeout 300 claude -p "$3
---
$(cat)" --model "$1" --append-system-prompt "$(cat "$2")" --allowedTools "Read Glob Grep" 2>&1
}

# rc2_reviewer_mainloop <rundir> <interval> <assess_fn> <label> — activity-gated loop: each tick, if
# tools.jsonl grew since last tick call `<assess_fn> <n>`, else skip (saves tokens). ONESHOT=1 runs one
# pass then returns. Exits on logs/.stop so the sidecar ends with the hunt even if started standalone.
rc2_reviewer_mainloop(){
  local rundir="$1" interval="$2" fn="$3" label="${4:-review}" tick=0 last_lines=-1 cur_lines
  if [ "${ONESHOT:-}" = "1" ]; then "$fn" 1; return 0; fi
  while [ ! -f "$rundir/logs/.stop" ]; do
    cur_lines="$(wc -l < "$rundir/logs/tools.jsonl" 2>/dev/null | tr -d ' ')"; cur_lines="${cur_lines:-0}"
    if [ "$cur_lines" != "$last_lines" ]; then tick=$((tick+1)); "$fn" "$tick"; last_lines="$cur_lines"
    else echo "${d:-}[$label] no new tool activity — holding (tick skipped, saves tokens)${n:-}"; fi
    sleep "$interval"
  done
}
