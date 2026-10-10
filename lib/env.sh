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
}

_rc2_is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# flag helpers (RC2_FLAG_RE, rc2_flag_value, rc2_hex_in, rc2_both_flags) live in common.sh,
# which bootstrap.sh sources before this file — one source of flag parsing for libs and scripts.
