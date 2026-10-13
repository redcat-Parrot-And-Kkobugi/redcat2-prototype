#!/usr/bin/env bash
# =============================================================================
#  env.sh — .env loading, SecLists, and flag helpers. Needs $RC2_ROOT (set by
#  bootstrap.sh). Part of the standalone lib; sourced via bootstrap.sh.
# =============================================================================

rc2_load_env() {
  # redcat2's OWN .env — no sibling project is read.
  [ -f "$RC2_ROOT/.env" ] || { echo "no $RC2_ROOT/.env — copy .env.example to .env and fill it"; return 1; }
  set -a; . "$RC2_ROOT/.env"; set +a
  : "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN (run: claude setup-token) in $RC2_ROOT/.env}"
  # SecLists: honour SECLISTS_DIR from env, else common location.
  export SECLISTS="${SECLISTS:-${SECLISTS_DIR:-$HOME/files_etc/SecLists}}"
  export SECLISTS="${SECLISTS/#\~/$HOME}"
  # HTB API client (bundled, sourceable). Non-fatal if absent — IP-only mode still works.
  if [ -f "$RC2_ROOT/scripts/lib/htb_api.sh" ]; then . "$RC2_ROOT/scripts/lib/htb_api.sh"; RC2_HTB=1; else RC2_HTB=0; fi
  unset ANTHROPIC_API_KEY   # force subscription auth; an API key would override + bill per-token

  # ── guard / rabbit-hole calibration defaults — SINGLE SOURCE OF TRUTH ──────────
  # Calibrated from this toolkit's own runs: solved boxes finished in ~186-416 tool calls;
  # the Nimbus rabbit hole burned 832 with no root. .env or the launch env overrides any of
  # these. All EXPORTED so the per-call hook (a separate process) inherits them.
  : "${RC2_CEIL:=800}"             # global experiment hard-stop (~2x slowest solved; Nimbus wedged near here)
  : "${RC2_WARN:=450}"             # global experiment warn line (just above the slowest solve, 416)
  : "${RC2_BUDGET_DEFAULT:=8}"     # per-hypothesis attempt budget seeded into ledger.json
  : "${RC2_REPEAT_FREEZE:=4}"      # identical-action repeats on one hypothesis before the hook warns/blocks
  : "${RC2_STALL:=12}"             # experiments on one hypothesis with no new evidence before the judge is asked
  : "${RC2_GATE_N:=2}"             # consecutive same-focus rabbit-hole reviews before oversee raises the live mode
  : "${RC2_GATE_MODE:=block}"      # mode oversee escalates the live tier to on consensus
  : "${GUARD_WATCH_INTERVAL:=180}" # sameness-judge watcher cadence, seconds
  : "${GUARD_JUDGE_MODEL:=claude-opus-4-8}" # sameness judge. PINNED to 4.8: Claude-5 aliases (sonnet/opus/
                                            # haiku) trip the real-time cyber safeguard on this work.
  : "${RC2_SURRENDER_MAX:=2}"      # max times the surrender gate may re-open a blocker and relaunch
  : "${RC2_SURRENDER_MODEL:=claude-opus-4-8}" # surrender-gate re-audit model (same 4.8 pin, same reason)
  export RC2_CEIL RC2_WARN RC2_BUDGET_DEFAULT RC2_REPEAT_FREEZE RC2_STALL RC2_GATE_N RC2_GATE_MODE GUARD_WATCH_INTERVAL GUARD_JUDGE_MODEL RC2_SURRENDER_MAX RC2_SURRENDER_MODEL
}

# rc2_pin_model <requested> — normalize a model arg to the 4.8 pin. The real-time cyber safeguard is
# CONTENT-based (it trips on host-escape work regardless of model), but the Claude-5 aliases
# (opus/sonnet/haiku, and any claude-*-5-* id) trip it HARDER and more often than 4.8 — and every
# sub-agent + out-of-band judge here is already pinned to claude-opus-4-8 — so the orchestrator is
# pinned to the same generation for one consistent, less-interrupted model across the whole hunt.
# An explicit 4.x id (claude-*-4-*) is honoured as-is. Escape hatches: RC2_NO_PIN=1 disables the
# policy entirely; RC2_PIN_MODEL overrides the pin target (e.g. a vetted CYBER_FALLBACK_MODEL).
rc2_pin_model() {
  local m="${1:-claude-opus-4-8}" pin="${RC2_PIN_MODEL:-claude-opus-4-8}"
  [ "${RC2_NO_PIN:-0}" = "1" ] && { printf '%s' "$m"; return; }
  case "$m" in
    claude-*-4-*) printf '%s' "$m" ;;    # explicit 4.x id — honour it
    *)            printf '%s' "$pin" ;;   # bare alias / Claude-5 id / unknown -> pin to 4.8
  esac
}

_rc2_is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# flag helpers (RC2_FLAG_RE, rc2_flag_value, rc2_hex_in, rc2_both_flags) live in common.sh,
# which bootstrap.sh sources before this file — one source of flag parsing for libs and scripts.
