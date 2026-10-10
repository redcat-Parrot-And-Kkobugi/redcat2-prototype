#!/usr/bin/env bash
# =============================================================================
#  common.sh — shared helpers for redcat2 scripts + libs. Idempotent; source it:
#      ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
#  Provides: ANSI colors (g r y c d n), rc2_resolve_rundir, rc2_to_epoch, rc2_utc,
#  and the flag helpers (RC2_FLAG_RE, rc2_flag_value, rc2_hex_in, rc2_both_flags).
# =============================================================================

# ANSI colors (plain; harmless when redirected)
g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; c=$'\033[36m'; d=$'\033[2m'; n=$'\033[0m'

# rc2_utc — one UTC timestamp format shared by journal / status / retrospectives
rc2_utc() { date -u +%FT%TZ; }

# rc2_load_target <rundir> — source <rundir>/target.env into the current shell (sets machine_name,
# target_ip, os_hint, difficulty, machine_id, tmux_base). Safe no-op if the file is absent. Callers
# that must not leak these into their own scope should call it inside a subshell.
rc2_load_target() {
  local f="${1:-.}/target.env"
  [ -f "$f" ] && . "$f"
  return 0
}

# ── flags (HTB flag = 32-hex) — the single source of flag parsing ──────────────
RC2_FLAG_RE='[0-9a-fA-F]{32}'
# rc2_flag_value <user|root> <rundir> — the captured hex from flags.txt, or empty.
rc2_flag_value() {
  local kind="$1" f="${2:-.}/flags.txt"
  [ -f "$f" ] && grep -ioE "^${kind}=$RC2_FLAG_RE" "$f" 2>/dev/null | head -1 | cut -d= -f2
}
# rc2_hex_in <file> — first 32-hex token in a file (e.g. a captured user.txt/root.txt), or empty.
rc2_hex_in() { grep -ioE "$RC2_FLAG_RE" "${1:-/dev/null}" 2>/dev/null | head -1; }
# rc2_both_flags <rundir> — true iff both user+root are present in flags.txt.
rc2_both_flags() {
  local f="${1:-.}/flags.txt"
  [ -f "$f" ] && grep -qiE "^user=$RC2_FLAG_RE" "$f" && grep -qiE "^root=$RC2_FLAG_RE" "$f"
}

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
