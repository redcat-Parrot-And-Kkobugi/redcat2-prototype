#!/usr/bin/env bash
# =============================================================================
#  machine.sh — convenience HTB machine ops over the API, outside a full hunt.
#  Token comes from .env (set by the HAR pipeline), client from scripts/lib/htb_api.sh.
#    machine.sh info   <name|id>        profile: name/id/os/difficulty/ip/retired/points
#    machine.sh ip     <name|id>        just the IP if known (active/spawned), else a hint
#    machine.sh spawn  <name|id>        spawn + wait for IP (15 x 3 min = 45 min), print it
#    machine.sh active                  the currently active machine + IP   (alias: status)
#    machine.sh stop   <name|id>        terminate            (alias: terminate)
#    machine.sh reset  <name|id>        reset
#    machine.sh submit <name|id> <flag> submit a flag        (alias: own)
#  A name is resolved to an id via the profile endpoint; a numeric id is used as-is.
#  Wait time: IP_WAIT_TRIES=15, IP_WAIT_INTERVAL=180 (15 x 3 min = 45 min); override via env.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/lib/common.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
. "$ROOT/scripts/lib/htb_api.sh"
: "${HTB_TOKEN:?set HTB_TOKEN in .env (drop a HAR in har/ and run ./hunt once, or set it directly)}"

_prof(){ htb_machine_profile "$1" 2>/dev/null; }
_id(){ htb_name_to_id "$1"; }   # name->id via the shared client helper
_msg(){ jq -rc '.message // .status // .' 2>/dev/null; }

cmd="${1:-}"; shift || true
case "$cmd" in
  info)
    _prof "${1:?usage: machine.sh info <name|id>}" \
      | jq -r '.info | "name=\(.name) id=\(.id) os=\(.os) difficulty=\(.difficultyText // .difficulty) ip=\(.ip // "-") retired=\(.retired) points=\(.points // "-")"' 2>/dev/null \
      || { echo "${r}no profile (bad name or dead token)${n}"; exit 1; } ;;
  ip)
    ip="$(_prof "${1:?usage: machine.sh ip <name|id>}" | jq -r '.info.ip // empty' 2>/dev/null)"
    if [ -n "$ip" ] && [ "$ip" != null ]; then echo "$ip"
    else a="$(htb_active 2>/dev/null | jq -r '.info.ip // empty' 2>/dev/null)"
         [ -n "$a" ] && echo "$a" || { echo "${y}no IP — not spawned. spawn it: machine.sh spawn $1${n}"; exit 1; }
    fi ;;
  spawn)
    id="$(_id "${1:?usage: machine.sh spawn <name|id>}")"; [ -n "$id" ] || { echo "${r}could not resolve id${n}"; exit 1; }
    echo "[spawn] machine id=$id ..."; htb_spawn "$id" | _msg
    tries="${IP_WAIT_TRIES:-15}"; interval="${IP_WAIT_INTERVAL:-180}"
    for i in $(seq 1 "$tries"); do
      ip="$(htb_active 2>/dev/null | jq -r '.info.ip // empty' 2>/dev/null)"
      [ -n "$ip" ] && [ "$ip" != null ] && { echo "${g}ip=$ip${n}"; exit 0; }
      echo "[spawn] waiting for IP ... ($i/$tries, ${interval}s)"; sleep "$interval"
    done
    echo "${y}timed out (~$((tries*interval/60))min); check: machine.sh active${n}"; exit 1 ;;
  active|status)
    htb_active 2>/dev/null | jq -r 'if .info then "active: \(.info.name) id=\(.info.id) ip=\(.info.ip)" else "no active machine" end' 2>/dev/null ;;
  stop|terminate)
    htb_terminate "$(_id "${1:?usage: machine.sh stop <name|id>}")" | _msg ;;
  reset)
    htb_reset "$(_id "${1:?usage: machine.sh reset <name|id>}")" | _msg ;;
  submit|own)
    htb_submit_flag "$(_id "${1:?usage: machine.sh submit <name|id> <flag>}")" "${2:?need a flag}" | _msg ;;
  ""|-h|--help|help) sed -n '3,15p' "$0" ;;
  *) echo "unknown: $cmd (try: machine.sh help)" >&2; exit 2 ;;
esac
