#!/usr/bin/env bash
# =============================================================================
#  surface_label.sh [<name|rundir>] — OPT-IN Tier-2 surface labeler (execution plan A3 Tier-2).
#  The per-call hook's _hook_surface gives cheap, deterministic, OBSERVABLE labels. This adds the
#  INFERRED layer (privesc-candidate, auth-bypass-surface, trust-boundary, …) that patterns can't —
#  one out-of-band model pass (haiku by default). Off by default; this is the optional enrichment for
#  the §5 gap digest. Writes logs/surfaces_inferred.json; gaps.sh folds it in when present. Reads only.
#    RC2_SURFACE_TIER2=1 scripts/surface_label.sh Nimbus
#    RC2_SURFACE_TIER2_MODEL=sonnet scripts/surface_label.sh Nimbus
#  (Runs regardless of the flag when invoked by hand; the flag is what lets gaps.sh auto-offer it.)
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
unset ANTHROPIC_API_KEY
: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in .env}"
: "${CLAUDE_CODE_PROMPT_CACHE_TTL:=1h}"; export CLAUDE_CODE_PROMPT_CACHE_TTL
command -v jq >/dev/null 2>&1 || { echo "surface_label.sh needs jq"; exit 1; }

RUNDIR="$(rc2_resolve_rundir "${1:-}" 2>/dev/null)"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "no run dir${1:+ for '$1'}"; exit 1; }
MODEL="${RC2_SURFACE_TIER2_MODEL:-haiku}"
SYS="$ROOT/SURFACE_LABEL.md"; TJ="$RUNDIR/logs/tools.jsonl"; WM="$RUNDIR/worldmodel.md"
OUT="$RUNDIR/logs/surfaces_inferred.json"

# digest: recent commands (observable actions) + worldmodel observed facts. No target contact.
digest="$( {
  echo "## recent actions (most recent last):"
  jq -r 'select(.event=="pre" and (.command!=null)) | .command' "$TJ" 2>/dev/null | tail -60 | cut -c1-200
  echo; echo "## worldmodel.md (observed facts):"
  sed -n '1,120p' "$WM" 2>/dev/null
} )"

echo "[surface-label] Tier-2 inferred labels for $RUNDIR (model=$MODEL) ..."
verdict="$(printf '%s' "$digest" | timeout 180 claude -p \
  "Label the surfaces below with INFERRED labels per the SURFACE-LABEL instructions. Output ONLY the strict JSON.
---
$(cat)" --model "$MODEL" --append-system-prompt "$(cat "$SYS")" --allowedTools "" 2>&1)"

json="$(printf '%s' "$verdict" | sed -n '/{/,/}/p' | tr -d '\000')"
if printf '%s' "$json" | jq -e '.surfaces' >/dev/null 2>&1; then
  printf '%s' "$json" | jq '{surfaces, note:(.note//""), at:(now|todate), model:"'"$MODEL"'"}' > "$OUT" 2>/dev/null \
    && echo "[surface-label] wrote $OUT" || echo "[surface-label] write failed"
else
  echo "[surface-label] model returned no parseable JSON (not written):" >&2
  printf '%s\n' "$verdict" | head -5 >&2
  exit 1
fi
