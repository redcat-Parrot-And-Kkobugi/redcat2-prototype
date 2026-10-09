#!/usr/bin/env bash
# =============================================================================
#  tools/env-setting/check_token.sh — validate .env for a solve.
#  Decodes HTB_TOKEN (aud/exp), LIVE-tests labs auth, and checks the other keys
#  solve.sh relies on. Exit 0 if the HTB token authenticates, 1 otherwise.
#    Usage:  tools/env-setting/check_token.sh
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env" 2>/dev/null; set +a; }
# shellcheck source=scripts/lib/htb_api.sh
. "$ROOT/scripts/lib/htb_api.sh"

g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; d=$'\033[2m'; n=$'\033[0m'
ok(){ echo "${g}✓${n} $*"; }; bad(){ echo "${r}✗${n} $*"; }; warn(){ echo "${y}!${n} $*"; }
rc=0

jwt_claims() {  # $1=token -> payload JSON on stdout
  local p; p="$(printf '%s' "$1" | cut -d. -f2)"
  local pad=$(( (4 - ${#p} % 4) % 4 )); p="${p}$(printf '=%.0s' $(seq 1 $pad))"
  printf '%s' "$p" | tr '_-' '/+' | base64 -d 2>/dev/null
}

echo "── HTB_TOKEN ──────────────────────────────────────────────"
if [ -z "${HTB_TOKEN:-}" ]; then
  bad "HTB_TOKEN not set in .env"; rc=1
else
  tok="$(printf '%s' "$HTB_TOKEN" | tr -d ' \r\n\t')"
  [ "$tok" != "$HTB_TOKEN" ] && warn "HTB_TOKEN had stray whitespace/CR — fix .env to LF-only"
  claims="$(jwt_claims "$tok")"
  aud="$(printf '%s' "$claims" | jq -r '.aud // "?"' 2>/dev/null)"
  exp="$(printf '%s' "$claims" | jq -r '.exp // 0' 2>/dev/null)"
  exph="$(printf '%s' "$claims" | jq -r 'if .exp then (.exp|todate) else "?" end' 2>/dev/null)"
  echo "${d}  aud=$aud   exp=$exph${n}"
  if [ "${exp%.*}" -lt "$(date +%s)" ] 2>/dev/null; then bad "token EXPIRED ($exph)"; rc=1
  else ok "not expired (exp $exph)"; fi
  # live auth test against labs
  resp="$(htb_active 2>/dev/null)"
  if printf '%s' "$resp" | jq -e 'has("info")' >/dev/null 2>&1; then
    ok "labs auth OK — token works (aud=$aud)"
  else
    err="$(printf '%s' "$resp" | jq -r '.error // .message // "no-json"' 2>/dev/null)"
    bad "labs auth FAILED: $err"; rc=1
    [ "$aud" != "6" ] && warn "aud=$aud — labs currently accepts aud=6 (web-app bearer). Get a working token from"
    [ "$aud" != "6" ] && warn "  the browser devtools (Authorization header / HAR) and set HTB_TOKEN in .env."
  fi
fi

echo; echo "── other solve.sh settings ────────────────────────────────"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ok "CLAUDE_CODE_OAUTH_TOKEN set" || { warn "CLAUDE_CODE_OAUTH_TOKEN empty (solve.sh needs it)"; }
[ -n "${SUDO_PASS:-}" ] && ok "SUDO_PASS set (sudo -A enabled)" || warn "SUDO_PASS empty (root cmds need NOPASSWD or will prompt)"
ov="${HTB_OVPN:-}"; ov="${ov/#\~/$HOME}"
if [ -n "$ov" ]; then [ -f "$ov" ] && ok "HTB_OVPN → $ov" || { bad "HTB_OVPN → $ov (file missing)"; rc=1; }
else warn "HTB_OVPN empty (VPN not auto-connected)"; fi
sl="${SECLISTS_DIR:-$HOME/files_etc/SecLists}"; sl="${sl/#\~/$HOME}"
[ -d "$sl/Discovery" ] && ok "SecLists → $sl" || { bad "SecLists missing at $sl (run install_tools.sh max)"; rc=1; }

echo
[ "$rc" -eq 0 ] && echo "${g}READY${n} — env OK for a solve." || echo "${r}NOT READY${n} — fix the ✗ items above."
exit "$rc"
