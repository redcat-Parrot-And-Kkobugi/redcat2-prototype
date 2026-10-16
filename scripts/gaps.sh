#!/usr/bin/env bash
# =============================================================================
#  gaps.sh [<name|rundir>] — the read-only digest the solver (4.8) reads WHEN STUCK to run the
#  enumeration-gap + combination pass (execution plan §5). It assembles three things, all grounded in
#  what was actually OBSERVED (no invention), so 4.8 can construct scenarios that cite provenance:
#    1. surface coverage  — per Tier-1 label EFFORT (from logs/accounting.json, which the solver may not
#                           read directly) → which surfaces got hammered vs barely touched.
#    2. log outcomes      — did recent attempts actually REACH a verdict, or FAULT/timeout/empty
#                           (inconclusive)? A surface with effort-but-all-inconclusive is NOT "tested"
#                           — re-angle it; a surface with zero effort is a true enumeration gap.
#    3. assets            — creds / services / files the worldmodel records (for the combination pass).
#  Reads only; no model call. This is COVERAGE, not a to-do list — 4.8 does the reasoning.
#    scripts/gaps.sh            # newest run
#    scripts/gaps.sh Nimbus
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || { echo "gaps.sh needs jq"; exit 1; }
RUNDIR="$(rc2_resolve_rundir "${1:-}" 2>/dev/null)"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "no run dir${1:+ for '$1'}"; exit 1; }
WM="$RUNDIR/worldmodel.md"; ACCT="$RUNDIR/logs/accounting.json"; TJ="$RUNDIR/logs/tools.jsonl"

echo "# SURFACE / GAP DIGEST — $RUNDIR"
echo "# (coverage + log outcomes + assets. Construct scenarios ONLY from these observed facts; cite each.)"
echo

echo "## 1. surface coverage — EFFORT per Tier-1 label (not success)"
if [ -s "$ACCT" ]; then
  jq -r '(.surfaces // {}) | to_entries | sort_by(-.value)[] | "  \(.value)\t\(.key)"' "$ACCT" 2>/dev/null | head -40
  echo "  (@host:port = effort on that target; bare labels = per-dimension effort. A label absent here = NOT yet touched = an enumeration gap.)"
else echo "  (no accounting.json yet)"; fi
echo

# Tier-2 inferred labels (opt-in): shown when surfaces_inferred.json exists. Offer to generate if enabled.
INF="$RUNDIR/logs/surfaces_inferred.json"
if [ -s "$INF" ]; then
  echo "## 1b. inferred labels (Tier-2, out-of-band) — semantic read of each surface"
  jq -r '(.surfaces // {}) | to_entries[] | select((.value|length)>0) | "  \(.key): \(.value|join(", "))"' "$INF" 2>/dev/null | head -30
  jq -r '.note // empty | select(length>0) | "  note: \(.)"' "$INF" 2>/dev/null
  echo
elif [ "${RC2_SURFACE_TIER2:-0}" = "1" ]; then
  echo "## 1b. inferred labels (Tier-2): enabled but not generated yet — run: scripts/surface_label.sh $(basename "$RUNDIR")"
  echo
fi

echo "## 2. log outcomes — did attempts REACH a verdict, or never run? (the log check)"
if [ -f "$TJ" ]; then
  local_total="$(grep -c '"event":"post"' "$TJ" 2>/dev/null)"; local_total="${local_total:-0}"
  nonzero="$(jq -r 'select(.event=="post" and (.exit!=null) and (.exit!=0)) | 1' "$TJ" 2>/dev/null | wc -l | tr -d ' ')"
  inconcl=0
  while read -r of; do
    [ -n "$of" ] && [ -f "$RUNDIR/logs/$of" ] || continue
    grep -qiE 'FAULT|timed out|timeout|connection (refused|reset)|curl: \(2[78]\)|curl: \(56\)|unpullable|failed to resolve image|\[cyber\]|empty reply|could not connect' "$RUNDIR/logs/$of" 2>/dev/null && inconcl=$((inconcl+1))
  done < <(jq -r 'select(.event=="post") | .out_file' "$TJ" 2>/dev/null | tail -80)
  echo "  post-actions=$local_total   nonzero-exit=$nonzero   inconclusive-signal(last 80)=$inconcl"
  echo "  recent inconclusive-looking results (never reached the mechanism — RE-ANGLE, don't refute):"
  while read -r of; do
    [ -n "$of" ] && [ -f "$RUNDIR/logs/$of" ] || continue
    if grep -qiE 'FAULT|timed out|timeout|connection (refused|reset)|curl: \(2[78]\)|unpullable|failed to resolve image|\[cyber\]' "$RUNDIR/logs/$of" 2>/dev/null; then
      sig="$(grep -ohiE 'FAULT|timed out|timeout|connection (refused|reset)|curl: \(2[78]\)|unpullable|failed to resolve image|\[cyber\]' "$RUNDIR/logs/$of" 2>/dev/null | head -1)"
      echo "    - logs/$of : $sig"
    fi
  done < <(jq -r 'select(.event=="post") | .out_file' "$TJ" 2>/dev/null | tail -40) | head -12
else echo "  (no tools.jsonl yet)"; fi
echo

echo "## 3. assets you hold (worldmodel observed facts — for the COMBINATION pass)"
if [ -s "$WM" ]; then
  for sec in 'Access held' 'Credentials' 'Services & versions' 'Notable files' 'Privilege map' 'Open questions'; do
    body="$(awk -v s="## $sec" '$0 ~ "^"s {f=1;print;next} /^## /{f=0} f' "$WM" 2>/dev/null | sed '1!{/^$/d}' | head -14)"
    [ -n "$body" ] && { printf '%s\n' "$body" | sed 's/^/  /'; echo; }
  done
else echo "  (no worldmodel.md yet)"; fi

echo "## HOW TO USE (§5): run TWO passes, each item citing a fact above —"
echo "  A) enumeration gap  — a surface with ZERO/low effort in §1 and NO facts in §3 → enumerate it (what is MISSING)."
echo "  B) combination       — assets in §3 you have not cross-applied (cred X -> service Y? file Z with X?)."
echo "  Do NOT re-enumerate a surface whose §2 attempts were INCONCLUSIVE — that is re-angle (§2 / conclusiveness), not a gap."
