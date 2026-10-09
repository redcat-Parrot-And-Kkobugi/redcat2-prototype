#!/usr/bin/env bash
# =============================================================================
#  common.sh — shared helpers for redcat2 scripts + libs. Idempotent; source it:
#      ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
#  Provides: ANSI colors (g r y c d n), rc2_resolve_rundir, rc2_to_epoch, rc2_say.
# =============================================================================

# ANSI colors (plain; harmless when redirected)
g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; c=$'\033[36m'; d=$'\033[2m'; n=$'\033[0m'

# rc2_resolve_rundir <arg> — needs $ROOT. Echoes a run dir:
#   a literal dir, else runs/<arg>, else the newest run. Empty output if none.
rc2_resolve_rundir() {
  local arg="${1:-}" root="${ROOT:?rc2_resolve_rundir needs \$ROOT}"
  if   [ -n "$arg" ] && [ -d "$arg" ];            then printf '%s\n' "$arg"
  elif [ -n "$arg" ] && [ -d "$root/runs/$arg" ]; then printf '%s\n' "$root/runs/$arg"
  else local dd; dd="$(ls -1dt "$root"/runs/*/ 2>/dev/null | head -1)"; printf '%s\n' "${dd%/}"; fi
}

# rc2_to_epoch <ts> — tools.jsonl timestamp (20261009T131917.061) -> epoch seconds (0 on fail)
rc2_to_epoch() {
  local t="${1%%.*}" dd cc
  dd="${t%T*}"; cc="${t#*T}"
  date -d "${dd:0:4}-${dd:4:2}-${dd:6:2} ${cc:0:2}:${cc:2:2}:${cc:4:2}" +%s 2>/dev/null || echo 0
}

# rc2_say <msg> — uniform log line to stderr
rc2_say() { printf '%s[redcat2]%s %s\n' "$c" "$n" "$*" >&2; }
