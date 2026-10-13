#!/usr/bin/env bash
# =============================================================================
#  replay.sh <run|name|ip> — re-run the confirmed_path exploit scripts (from
#  ledger.json) in order, to RE-ESTABLISH a proven access chain against the LIVE
#  target instead of re-deriving it. Each confirmed script re-pulls dynamic
#  values (creds/tokens/flags), so replay works even after the box respawned and
#  the IP/flags rotated. Operator helper; the solver does the same on resume
#  (doctrine 40 → Resume). Fail-open per step: a failed step is reported, not fatal.
#    scripts/replay.sh Nimbus
#    REPLAY_STEP_TIMEOUT=600 scripts/replay.sh Nimbus
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"   # provides colors g/r/c/d/n + rc2_resolve_rundir

RUNDIR="$(rc2_resolve_rundir "${1:-}")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "replay: no run dir for '${1:-}'" >&2; exit 1; }
led="$RUNDIR/ledger.json"
[ -s "$led" ] || { echo "replay: no ledger.json in $(basename "$RUNDIR") (nothing confirmed yet)"; exit 0; }

cnt="$(jq -r '[.confirmed_path[]? | select(.script)] | length' "$led" 2>/dev/null)"; cnt="${cnt:-0}"
[ "$cnt" -gt 0 ] 2>/dev/null || { echo "replay: confirmed_path has no runnable scripts yet — nothing to replay"; exit 0; }

echo "${c}[replay]${n} $(basename "$RUNDIR"): replaying $cnt confirmed step(s) against the live target"
cd "$RUNDIR" || exit 1
# shellcheck source=/dev/null
[ -f target.env ] && { set -a; . target.env 2>/dev/null; set +a; }   # export target_ip etc. to child scripts
export RC2_TMUX="${tmux_base:-rc2}_main"

fail=0 i=0 tmo="${REPLAY_STEP_TIMEOUT:-300}"
while IFS=$'\t' read -r script summary yields; do
  [ -n "$script" ] || continue
  i=$((i+1))
  echo "— [$i/$cnt] ${summary:-?}   ($script → ${yields:-?})"
  if [ ! -f "$script" ]; then echo "    ${r}MISSING${n}: $script (re-derive this step)"; fail=$((fail+1)); continue; fi
  if timeout "$tmo" bash "$script"; then echo "    ${g}ok${n}"
  else echo "    ${r}FAILED${n} (re-derive this step, then update its script)"; fail=$((fail+1)); fi
done < <(jq -r '.confirmed_path[]? | select(.script) | [.script, (.summary//""), (.yields//"")] | @tsv' "$led" 2>/dev/null)

echo "[replay] done — $((cnt-fail))/$cnt ok$( [ "$fail" -gt 0 ] && echo ", $fail need re-derive" )"
[ "$fail" -eq 0 ]
