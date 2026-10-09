#!/usr/bin/env bash
# =============================================================================
#  rag.sh — cross-run memory. Lightweight ripgrep retrieval over the agent's OWN
#  past runs (every runs/<slug>/: journal.md, worldmodel.md, hypotheses.md, writeup.md,
#  failure_analysis.md, notes/, research/). No vector DB. The agent calls this to
#  recall "have I seen this service / tech / error before, and what worked or failed".
#
#  Usage:
#     scripts/rag.sh <query...>            # search all past runs
#     scripts/rag.sh -p <query...>         # ALSO search shared refs (PayloadsAllTheThings, GTFOBins)
#     SCOPE=runs/blizzard scripts/rag.sh <q>   # restrict to one run dir
#
#  Deliberately does NOT ship a methodology/knowledge corpus — redcat2 researches the
#  live internet (see doctrine/20) and remembers only its own evidence.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WITH_PAYLOADS=0; [ "${1:-}" = "-p" ] && { WITH_PAYLOADS=1; shift; }
Q="$*"; [ -n "$Q" ] || { echo "usage: rag.sh [-p] <query...>" >&2; exit 2; }

paths=()
if [ -n "${SCOPE:-}" ]; then paths+=("$ROOT/$SCOPE")
else
  paths+=("$ROOT/runs")
  if [ "$WITH_PAYLOADS" -eq 1 ]; then
    paths+=("$HOME/files_etc/PayloadsAllTheThings" "$HOME/files_etc/GTFOBins")   # shared external refs (NOT SecLists — too large)
  fi
fi
real=(); for p in "${paths[@]}"; do [ -e "$p" ] && real+=("$p"); done
[ ${#real[@]} -gt 0 ] || { echo "[rag] nothing to search yet (no past runs)" >&2; exit 1; }

# Search human-readable memory (journal/worldmodel/hypotheses/writeup/failure_analysis/notes/
# research), not the raw tool logs or binaries — those are noise for recall.
if command -v rg >/dev/null 2>&1; then
  rg -i -. --heading --color=never -n -C2 \
     -g '!*.jpg' -g '!*.png' -g '!*.gz' -g '!*.zip' -g '!*.pcap*' -g '!.git' \
     -g '!**/logs/**' -g '!**/bin/**' -g '!**/loot/**' -g '!**/tmp/**' \
     -e "$Q" "${real[@]}" 2>/dev/null \
   || echo "[rag] no matches for: $Q"
else
  grep -rinI -C2 --color=never \
     --exclude-dir=.git --exclude-dir=logs --exclude-dir=bin --exclude-dir=loot --exclude-dir=tmp \
     -e "$Q" "${real[@]}" 2>/dev/null \
   || echo "[rag] no matches for: $Q"
fi
