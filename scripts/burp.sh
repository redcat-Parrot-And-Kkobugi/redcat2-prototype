#!/usr/bin/env bash
# =============================================================================
#  scripts/burp.sh [up|status|down|restart] — one command → Burp usable over MCP.
#
#  OPTIONAL capability. Run it BEFORE ./hunt when you want the agent to drive Burp
#  (Repeater/Intruder/Scanner, session handling) on a web-heavy box. `up` launches
#  Burp Suite Pro + the BurpMCP-Ultra extension in a PERSISTENT tmux session under a
#  headless Xvfb display, waits for the MCP server, and registers it with Claude Code
#  at user scope so ./hunt's `claude -p` inherits `mcp__burp__*`.
#
#    scripts/burp.sh          # = up (idempotent: re-register if already running)
#    scripts/burp.sh status   # tmux session, live MCP port, claude registration
#    scripts/burp.sh down      # stop the Burp tmux session (Xvfb torn down with it)
#    scripts/burp.sh restart  # down + up
#
#  Config (redcat2/.env): BURP_MCP_TOKEN (required — from Ultra's Server tab, stable).
#  Overrides: BURP_JAR, BURP_LOADER, BURP_PROJECT, BURP_TMUX, BURP_DISPLAY(=xvfb | :0 for WSLg).
#  The Burp install itself is a shared external resource (files_etc), not part of redcat2.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; d=$'\033[2m'; n=$'\033[0m'

BURP_DIR_DEFAULT="/home/kali/files_etc/burpsuitepro/Burpsuite-Professional/Burpsuite-Professional"
BURP_JAR="${BURP_JAR:-$BURP_DIR_DEFAULT/burpsuite_pro_v2026.jar}"
BURP_LOADER="${BURP_LOADER:-$BURP_DIR_DEFAULT/loader.jar}"
BURP_PROJECT="${BURP_PROJECT:-$ROOT/burp_proj/redcat2.burp}"   # Burp creates it on first run
SESS="${BURP_TMUX:-rc2_burp}"
TOKEN="${BURP_MCP_TOKEN:-}"
DISPLAY_MODE="${BURP_DISPLAY:-xvfb}"
PORTS=(9876 9877)

live_port(){
  [ -n "$TOKEN" ] || return 1
  local p code
  for p in "${PORTS[@]}"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$p/$TOKEN/" 2>/dev/null)"
    [ "$code" = "200" ] && { echo "$p"; return 0; }
  done
  return 1
}
register(){
  claude mcp remove --scope user burp >/dev/null 2>&1 || true
  claude mcp add --scope user --transport sse burp "http://127.0.0.1:$1/$TOKEN/" >/dev/null 2>&1 \
    && echo "${g}✓ registered burp MCP → http://127.0.0.1:$1/<token>/ (user scope)${n}" \
    || echo "${r}✗ claude mcp add failed${n}"
}

cmd="${1:-up}"
case "$cmd" in
  status)
    tmux has-session -t "$SESS" 2>/dev/null && echo "${g}tmux '$SESS': running${n}" || echo "${y}tmux '$SESS': not running${n}"
    if p="$(live_port)"; then echo "${g}MCP: live on :$p (token OK)${n}"; else echo "${y}MCP: not reachable / not authenticated${n}"; fi
    claude mcp list 2>/dev/null | grep -i '^burp' || echo "burp: not registered with Claude Code"
    ;;
  down)
    tmux kill-session -t "$SESS" 2>/dev/null && echo "${g}stopped tmux '$SESS'${n}" || echo "${y}no '$SESS' session${n}"
    pkill -f "burpsuite_pro.*--project-file=$BURP_PROJECT" 2>/dev/null || true
    ;;
  restart) "$0" down; exec "$0" up ;;
  up)
    : "${TOKEN:?set BURP_MCP_TOKEN in redcat2/.env (from Ultra Server tab)}"
    if p="$(live_port)"; then echo "${g}Burp MCP already up on :$p${n}"; register "$p"; exit 0; fi
    [ -r "$BURP_JAR" ] || { echo "${r}missing Burp jar: $BURP_JAR  (set BURP_JAR in .env)${n}"; exit 1; }
    command -v tmux >/dev/null || { echo "${r}tmux not installed${n}"; exit 1; }
    mkdir -p "$(dirname "$BURP_PROJECT")"
    AO="--add-opens=java.desktop/javax.swing=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED --add-opens=java.base/jdk.internal.org.objectweb.asm.tree=ALL-UNNAMED --add-opens=java.base/jdk.internal.org.objectweb.asm.Opcodes=ALL-UNNAMED"
    JCMD="java $AO -javaagent:'$BURP_LOADER' -noverify -jar '$BURP_JAR' --project-file='$BURP_PROJECT'"
    if [ "$DISPLAY_MODE" = "xvfb" ]; then
      command -v xvfb-run >/dev/null || { echo "${y}installing xvfb...${n}"; sudo -A apt-get install -y xvfb >/dev/null 2>&1 || true; }
      LAUNCH="exec xvfb-run -a -s '-screen 0 1600x1000x24' $JCMD"
    else
      LAUNCH="export DISPLAY='$DISPLAY_MODE'; exec $JCMD"
    fi
    echo "[burp] launching in tmux '$SESS' (${DISPLAY_MODE}) with project $(basename "$BURP_PROJECT") ..."
    tmux kill-session -t "$SESS" 2>/dev/null || true
    tmux new-session -d -s "$SESS" "bash -lc \"$LAUNCH\""
    echo "[burp] waiting for MCP server (Burp start + extension load, ~30-90s) ..."
    for i in $(seq 1 60); do
      if p="$(live_port)"; then
        echo "${g}✓ Burp MCP up on :$p after ~$((i*3))s${n}"; register "$p"
        echo "${d}  watch Burp:  tmux attach -t $SESS   |  dashboard: http://127.0.0.1:9878${n}"
        echo "${d}  the agent uses it as mcp__burp__* (new ./hunt runs pick it up).${n}"; exit 0
      fi
      tmux has-session -t "$SESS" 2>/dev/null || { echo "${r}✗ tmux session died — check: tmux capture-pane -pt $SESS${n}"; exit 1; }
      sleep 3
    done
    echo "${r}✗ MCP not up after 180s. Attach to debug: tmux attach -t $SESS${n}"; exit 1
    ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
