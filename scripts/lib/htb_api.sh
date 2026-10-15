#!/usr/bin/env bash
# =============================================================================
#  htb_api.sh — thin HTB API helper (source it, or run a subcommand).
#  Auth: HTB **App Token** — create at https://app.hackthebox.com/account-settings → "Create App Token".
#  Put it in .env as HTB_TOKEN. Base/paths/versions verified against the maintained htb-operator CLI
#  (user0x1337/htb-operator): GET machine/* on v4, vm/* POST on v4, flag submission on **v5**.
# =============================================================================
# The official Postman doc shows www.hackthebox.com/api/v4, but that host is now the marketing site;
# the live API is labs.hackthebox.com (v4 for machine/vm, v5 for flag submission + machine listing).
HTB_API_BASE="${HTB_API_BASE:-https://labs.hackthebox.com/api/v4}"
HTB_API_BASE_V5="${HTB_API_BASE_V5:-${HTB_API_BASE/\/v4/\/v5}}"   # derive v5 base from v4
HTB_UA="${HTB_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36}"
HTB_OWN_ENDPOINT="${HTB_OWN_ENDPOINT:-machine/own}"   # flag submission path (on v5)

_htb_need_token() {
  [ -n "${HTB_TOKEN:-}" ] && return 0
  echo "[htb_api] HTB_TOKEN not set. Create an App Token at https://app.hackthebox.com/account-settings and put it in .env" >&2
  return 1
}

# htb_req METHOD ENDPOINT [JSON_BODY] -> response body on stdout. Headers mirror htb-operator.
htb_req() {
  local method="$1" ep="$2" body="${3:-}"
  _htb_need_token || return 1
  local args=(-sS --max-time 180 -X "$method"
    -H "Authorization: Bearer ${HTB_TOKEN}"
    -H "Accept: application/json, text/plain, */*"
    -H "User-Agent: ${HTB_UA}"
    -H "Referer: https://app.hackthebox.com/"
    -H "Origin: https://app.hackthebox.com")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" "${HTB_API_BASE}/${ep}"
}

htb_machine_profile() { htb_req GET  "machine/profile/$1"; }          # $1 = name or id (v4)
htb_name_to_id()      { case "$1" in ''|*[!0-9]*) htb_machine_profile "$1" 2>/dev/null | jq -r '.info.id // empty' 2>/dev/null ;; *) echo "$1" ;; esac; }  # name->id; a numeric id passes through
# active machine is on v5 as virtual_machine/active (confirmed from app.hackthebox.com devtools HAR)
htb_active()          { HTB_API_BASE="$HTB_API_BASE_V5" htb_req GET "virtual_machine/active"; }
htb_spawn()           { htb_req POST "vm/spawn"     "{\"machine_id\": $1}"; }   # v4
htb_terminate()       { htb_req POST "vm/terminate" "{\"machine_id\": $1}"; }   # v4
htb_reset()           { htb_req POST "vm/reset"     "{\"machine_id\": $1}"; }   # v4
# flag submission is on v5 (per htb-operator): POST v5/machine/own {machine_id, flag}
htb_submit_flag()     { HTB_API_BASE="$HTB_API_BASE_V5" htb_req POST "$HTB_OWN_ENDPOINT" "{\"machine_id\": $1, \"flag\": \"$2\"}"; }  # $1=id $2=flag

# Allow running as a CLI too:  htb_api.sh profile <name> | active | spawn <id> | ...
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # load .env from repo root so HTB_TOKEN is available when run directly
  _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  [ -f "$_root/.env" ] && { set -a; . "$_root/.env"; set +a; }
  cmd="${1:-}"; shift || true
  case "$cmd" in
    profile)   htb_machine_profile "$@";;
    active)    htb_active;;
    spawn)     htb_spawn "$@";;
    terminate) htb_terminate "$@";;
    reset)     htb_reset "$@";;
    own|flag)  htb_submit_flag "$@";;
    "")        echo "usage: htb_api.sh {profile <name|id>|active|spawn <id>|terminate <id>|reset <id>|own <id> <flag>}" >&2; exit 2;;
    *)         echo "unknown subcommand: $cmd" >&2; exit 2;;
  esac
fi
