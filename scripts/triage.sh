#!/usr/bin/env bash
# =============================================================================
#  triage.sh [<name|rundir>] — the lightweight per-run retrospective (execution plan §4).
#  Folds each run's analyze_run.sh classification into ONE strategic question:
#  did the run die from THOUGHT (wrong vector / incomplete enumeration / premature surrender)
#  or from EXECUTION (right vector but couldn't land it / shell died / interactive failed)?
#  That tag tells where the remaining effort should go (§2 execution vs §5 enumeration).
#
#  Deterministic over logs/failure_analysis.json (+ flags.txt); no model call. Reads only.
#  No arg -> every run under runs/ (a cross-run rollup). A name/dir -> just that run.
#    scripts/triage.sh            # all runs, with an aggregate
#    scripts/triage.sh Nimbus     # one run
#    BAKS=1 scripts/triage.sh     # include *.bak.* archived runs too (default: skip)
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || { echo "triage.sh needs jq"; exit 1; }

# _triage_bucket <rundir> -> "<bucket>\t<detail>"  (bucket: solved|execution|thought|ambiguous|unknown)
_triage_bucket() {
  local d="$1" fa="$1/failure_analysis.json" outcome cat top solved
  solved=no
  # solved = both flags present (user + root), or analyze_run said so
  if grep -qiE '^user=' "$d/flags.txt" 2>/dev/null && grep -qiE '^root=' "$d/flags.txt" 2>/dev/null; then solved=yes; fi
  [ -s "$fa" ] || { printf 'unknown\t(no failure_analysis.json)'; return; }
  outcome="$(jq -r '.outcome // ""' "$fa" 2>/dev/null)"
  case "$outcome" in solved|owned|success) solved=yes ;; esac
  [ "$solved" = yes ] && { printf 'solved\toutcome=%s' "${outcome:-flags}"; return; }
  # dominant failure category: primary_category if present, else argmax of category_scores
  cat="$(jq -r '.failure_analysis.primary_category // ""' "$fa" 2>/dev/null)"
  [ -n "$cat" ] || cat="$(jq -r '(.category_scores // {}) | to_entries | max_by(.value) | .key // ""' "$fa" 2>/dev/null)"
  case "$cat" in
    tool_execution|state_mgmt)        printf 'execution\t%s' "$cat" ;;
    planning|hypothesis|observation)  printf 'thought\t%s' "$cat" ;;
    idle_wait)                        printf 'ambiguous\t%s (idle — could be waiting on a dead vector OR stuck choosing)' "$cat" ;;
    "")                               printf 'unknown\t(no category)' ;;
    *)                                printf 'ambiguous\t%s' "$cat" ;;
  esac
}

_one() {
  local d="$1" slug; slug="$(basename "$d")"
  local b bucket detail steps diff
  b="$(_triage_bucket "$d")"; bucket="${b%%$'\t'*}"; detail="${b#*$'\t'}"
  steps="$(jq -r '.steps // "?"' "$d/failure_analysis.json" 2>/dev/null || echo '?')"
  diff="$(jq -r '.difficulty // "?"' "$d/failure_analysis.json" 2>/dev/null || echo '?')"
  printf '%-26s %-10s %-5s %-6s %s\n' "$slug" "$bucket" "$diff" "${steps}st" "$detail"
  printf '%s\n' "$bucket" >> "$_TALLY"
}

main() {
  local arg="${1:-}"
  _TALLY="$(mktemp)"; : > "$_TALLY"
  printf '%-26s %-10s %-5s %-6s %s\n' "RUN" "VERDICT" "DIFF" "STEPS" "WHY"
  printf '%s\n' "------------------------------------------------------------------------------"
  if [ -n "$arg" ]; then
    local rd; rd="$(rc2_resolve_rundir "$arg" 2>/dev/null)"; [ -d "${rd:-}" ] || rd="$ROOT/runs/$arg"
    [ -d "$rd" ] && _one "$rd" || { echo "no run dir for '$arg'"; rm -f "$_TALLY"; exit 1; }
  else
    local d
    for d in "$ROOT"/runs/*/; do
      [ -d "$d" ] || continue
      case "$(basename "$d")" in *.bak.*) [ "${BAKS:-0}" = 1 ] || continue ;; esac
      _one "$d"
    done
  fi
  echo
  echo "AGGREGATE (the §4 signal — where to invest):"
  sort "$_TALLY" | uniq -c | sort -rn | awk '{printf "  %-10s %s\n", $2, $1}'
  echo
  echo "  execution-heavy -> invest in §2 (interactive/exploit reliability)."
  echo "  thought-heavy   -> invest in §5 (enumeration-gap + combination) / research quality."
  echo "  (idle/ambiguous -> read that run's journal.md to disambiguate — the 10-min human pass.)"
  rm -f "$_TALLY"
}
main "$@"
