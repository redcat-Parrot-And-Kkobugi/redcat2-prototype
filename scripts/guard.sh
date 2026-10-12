#!/usr/bin/env bash
# =============================================================================
#  guard.sh <rundir|name|ip> <off|warn|block> [reason] — set the LIVE guard mode.
#  This is the supervisor/operator channel (the "live" tier). It writes
#  logs/guard.mode tagged with logs/.guard_secret so the solver cannot forge it.
#  Effective enforcement = the STRONGER of this live mode and the operator's
#  RC2_GUARD floor (env, set at ./hunt launch) — see doctrine 10 → the guard.
#    guard.sh Nimbus block "rabbit-hole: N-consensus on floci escape"
#    guard.sh Nimbus warn            # de-escalate (never below the operator floor)
#    guard.sh Nimbus show            # print floor hint + current live mode
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

RUNDIR="$(rc2_resolve_rundir "${1:?usage: guard.sh <run> <off|warn|block|show> [reason]}")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "guard: no run dir for '$1'" >&2; exit 1; }
mode="${2:?usage: guard.sh <run> <off|warn|block|show> [reason]}"
reason="${3:-}"
L="$RUNDIR/logs"; gm="$L/guard.mode"; sec="$L/.guard_secret"

if [ "$mode" = "show" ]; then
  echo "run:   $(basename "$RUNDIR")"
  echo "floor: ${RC2_GUARD:-off}   (operator env at launch; live can never go below it)"
  echo "live:  $( [ -s "$gm" ] && { sed -n 's/^mode=//p' "$gm" | head -1; } || echo 'none (=> effective is the floor)')"
  exit 0
fi
case "$mode" in off|warn|block) ;; *) echo "guard: mode must be off|warn|block|show" >&2; exit 2;; esac
[ -s "$sec" ] || { echo "guard: no $sec (hunt writes it at scaffold) — cannot tag a trusted live mode" >&2; exit 1; }

tag="$(printf '%s%s' "$mode" "$(cat "$sec")" | md5sum | cut -c1-32)"
{ echo "mode=$mode"; echo "tag=$tag"; } > "$gm.tmp" && mv "$gm.tmp" "$gm"
printf '%s set live=%s%s\n' "$(rc2_utc)" "$mode" "${reason:+ ($reason)}" >> "$L/guard.log" 2>/dev/null || true
echo "[guard] live mode = '$mode' for $(basename "$RUNDIR")${reason:+  — $reason}  (effective = max(floor ${RC2_GUARD:-off}, $mode))"
