#!/usr/bin/env bash
# =============================================================================
#  tools/env-setting/set_token_from_har.sh <file.har> — refresh HTB_TOKEN from a
#  devtools HAR. Extracts the Bearer token the web app sends to labs.hackthebox.com,
#  VERIFIES it authenticates to the labs machine API, then writes it to .env.
#
#  Use when the labs token expires: in the browser (app.hackthebox.com, logged in)
#  open DevTools → Network → right-click a request → Save all as HAR → pass it here.
#    Usage:  tools/env-setting/set_token_from_har.sh ~/Downloads/app.hackthebox.com.har
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HAR="${1:?usage: set_token_from_har.sh <file.har>}"
[ -f "$HAR" ] || { echo "no such file: $HAR"; exit 2; }
g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; d=$'\033[2m'; n=$'\033[0m'
# shellcheck source=scripts/lib/htb_api.sh
. "$ROOT/scripts/lib/htb_api.sh"

echo "[har] extracting labs Bearer token ..."
tok="$(jq -r '
  .log.entries[] | select(.request.url|test("labs\\.hackthebox\\.com/api"))
  | .request.headers[] | select(.name|test("^authorization$";"i")) | .value
' "$HAR" 2>/dev/null | head -1 | sed 's/^[Bb]earer //' | tr -d ' \r\n\t')"
[ -n "$tok" ] || { echo "${r}no labs Authorization bearer found in HAR${n} (capture while logged in to app.hackthebox.com)"; exit 1; }

# decode aud/exp
p="$(printf '%s' "$tok" | cut -d. -f2)"; pad=$(((4-${#p}%4)%4)); p="${p}$(printf '=%.0s' $(seq 1 $pad))"
claims="$(printf '%s' "$p" | tr '_-' '/+' | base64 -d 2>/dev/null)"
aud="$(printf '%s' "$claims" | jq -r '.aud//"?"' 2>/dev/null)"
exph="$(printf '%s' "$claims" | jq -r 'if .exp then(.exp|todate)else"?"end' 2>/dev/null)"
echo "${d}  token: aud=$aud  exp=$exph  len=${#tok}${n}"

echo "[verify] testing against labs machine API ..."
resp="$(HTB_TOKEN="$tok" htb_active 2>/dev/null)"
if ! printf '%s' "$resp" | jq -e 'has("info")' >/dev/null 2>&1; then
  err="$(printf '%s' "$resp" | jq -r '.error // .message // "no-json"' 2>/dev/null)"
  echo "${r}✗ token does NOT authenticate to labs: $err${n}"
  echo "  (is the HAR fresh / captured while logged in? labs needs an aud=6 web-app token.)"
  exit 1
fi
echo "${g}✓ labs auth OK${n}"

# write to .env (LF-safe, timestamped backup)
ENV="$ROOT/.env"; [ -f "$ENV" ] || : > "$ENV"
cp "$ENV" "$ENV.bak.$(date +%s)"
# token is passed on fd 3 (a here-string), never on argv — keeps it out of `ps`
# and any tool-call log. only $ENV (not secret) is an argument.
python3 - "$ENV" 3<<<"$tok" <<'PY'
import sys,os,re
env=sys.argv[1]
tok=os.fdopen(3,encoding="utf-8").read().strip()   # strip trailing \n / CRLF from fd
s=open(env,encoding="utf-8").read()
if re.search(r'^HTB_TOKEN=',s,re.M): s=re.sub(r'^HTB_TOKEN=.*$','HTB_TOKEN='+tok,s,flags=re.M)
else: s=(s.rstrip('\n')+'\n' if s else '')+'HTB_TOKEN='+tok+'\n'
open(env,"w",encoding="utf-8",newline="\n").write(s)
PY
echo "${g}✓ HTB_TOKEN updated in .env${n} (backup: .env.bak.*; gitignored)"
echo "[check] running env check ..."
"$ROOT/tools/env-setting/check_token.sh" || true
