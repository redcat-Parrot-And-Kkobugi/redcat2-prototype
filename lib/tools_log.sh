#!/usr/bin/env bash
# =============================================================================
#  tools_log.sh — shared readers for logs/tools.jsonl (the force-logging hook's output).
#  ONE place that knows the record shape (event/tool/command/ts/exit/out_bytes/out_file),
#  so report.sh, the status writer, analyze_run, and the flag scanner don't each re-derive
#  the grep/jq. Needs jq for the richer helpers; all are safe on a missing/empty file.
#  Sourced via bootstrap.sh (for libs) and by the scripts that need it.
# =============================================================================

rc2_tl_posts()    { grep '"event":"post"' "${1:-/dev/null}" 2>/dev/null; }   # raw post-event lines
rc2_tl_count()    {                         # <jsonl> [tool] — count post events (optionally one tool)
  local j="${1:-/dev/null}" t="${2:-}"
  if [ -n "$t" ]; then rc2_tl_posts "$j" | grep -c "\"tool\":\"$t\""
  else grep -c '"event":"post"' "$j" 2>/dev/null; fi
}
rc2_tl_first_ts() { grep -m1 '"event":"pre"' "${1:-/dev/null}" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null | head -1; }
rc2_tl_last_ts()  { rc2_tl_posts "${1:-/dev/null}" | tail -1 | jq -r '.ts // empty' 2>/dev/null | head -1; }
rc2_tl_dur_ms()   { rc2_tl_posts "${1:-/dev/null}" | jq -s 'map(.duration_ms // 0)|add // 0' 2>/dev/null | head -1; }
rc2_tl_recent()   {                         # <jsonl> [n] — last n post calls as "- [ts] tool cmd (bytes)"
  tail -40 "${1:-/dev/null}" 2>/dev/null \
    | jq -r 'select(.event=="post") | "- [\(.ts)] \(.tool) \((.command // "")[0:100]) (\(.out_bytes)B)"' 2>/dev/null \
    | tail -"${2:-15}"
}
