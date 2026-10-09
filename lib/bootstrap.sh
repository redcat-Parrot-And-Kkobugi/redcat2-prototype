#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh — redcat2 environment, HTB resolution, VPN, and run-dir scaffold.
#  Sourced by ./hunt. Fully standalone: the HTB API client (scripts/lib/htb_api.sh),
#  the HAR token extractor (tools/env-setting/), and the log renderer are bundled.
# =============================================================================
RC2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# redcat2 is fully standalone: all tokens, the HTB API client, the HAR extractor, and the log
# renderer live inside this tree. $SECLISTS (~/files_etc/SecLists) is a shared external wordlist
# resource, not part of any sibling project.

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

# Is the current HTB_TOKEN live against the labs API? (auth works -> response has an "info" key)
_rc2_token_live() {
  [ "${RC2_HTB:-0}" = "1" ] && [ -n "${HTB_TOKEN:-}" ] || return 1
  htb_active 2>/dev/null | jq -e 'has("info")' >/dev/null 2>&1
}

# HAR-driven token automation (bundled extractor). Drop a fresh devtools HAR from a logged-in
# app.hackthebox.com into redcat2/har/; this finds the newest, extracts the aud:6 labs bearer, verifies
# it against the live API, and writes it to redcat2/.env. Returns 0 if a live token is in place
# afterwards. Non-fatal: IP-only targets continue without it; name targets need it.
rc2_ensure_htb_token() {
  if [ "${RC2_HTB:-0}" != "1" ]; then echo "[token] scripts/lib/htb_api.sh missing — IP-only mode"; return 1; fi
  if _rc2_token_live; then echo "[token] HTB token OK (live auth)"; return 0; fi
  mkdir -p "$RC2_ROOT/har" 2>/dev/null
  local har extractor="$RC2_ROOT/tools/env-setting/set_token_from_har.sh"
  har="$(ls -t "$RC2_ROOT"/har/*.har 2>/dev/null | head -1)"
  if [ -n "$har" ] && [ -x "$extractor" ]; then
    echo "[token] token missing/expired — extracting from newest HAR: $(basename "$har")"
    "$extractor" "$har" >/dev/null 2>&1 || true
    rc2_load_env                      # re-source: the fresh token was written to redcat2/.env
    if _rc2_token_live; then echo "[token] refreshed from HAR ✓"; return 0; fi
    echo "[token] HAR found but token still invalid (stale HAR, or not captured while logged in)"
  else
    echo "[token] no usable HAR in $RC2_ROOT/har/ (save one from app.hackthebox.com devtools)"
  fi
  return 1
}

# Resolve target -> sets globals: TARGET_IP MACHINE_NAME MACHINE_ID OS_HINT DIFFICULTY
rc2_resolve_target() {
  local t="$1"
  TARGET_IP=""; MACHINE_NAME=""; MACHINE_ID=""; OS_HINT=""; DIFFICULTY=""
  if _rc2_is_ip "$t"; then
    TARGET_IP="$t"; MACHINE_NAME="$t"
    echo "[htb] IP target $t — name/spawn/submit disabled (give a machine name + HTB_TOKEN for the full path)"
    return 0
  fi
  [ "${RC2_HTB:-0}" = "1" ] && [ -n "${HTB_TOKEN:-}" ] || {
    echo "[htb] '$t' is a NAME but no HTB API/token available. Pass an IP, or set HTB_TOKEN in redcat2/.env (or drop a fresh HAR in har/)."; return 1; }
  local prof; prof="$(htb_machine_profile "$t" 2>/dev/null)"
  MACHINE_NAME="$(printf '%s' "$prof" | jq -r '.info.name // empty' 2>/dev/null)"
  MACHINE_ID="$(printf '%s'   "$prof" | jq -r '.info.id // empty'   2>/dev/null)"
  OS_HINT="$(printf '%s'      "$prof" | jq -r '.info.os // empty'   2>/dev/null)"
  DIFFICULTY="$(printf '%s'   "$prof" | jq -r '.info.difficultyText // empty' 2>/dev/null)"
  TARGET_IP="$(printf '%s'    "$prof" | jq -r '.info.ip // empty'   2>/dev/null)"
  [ -n "$MACHINE_NAME" ] || { echo "[htb] could not resolve machine '$t' (bad name or dead token)"; return 1; }
  if [ -z "$TARGET_IP" ] || [ "$TARGET_IP" = "null" ]; then
    # maybe already active?
    local act; act="$(htb_active 2>/dev/null)"
    if [ "$(printf '%s' "$act" | jq -r '.info.id // empty' 2>/dev/null)" = "$MACHINE_ID" ]; then
      TARGET_IP="$(printf '%s' "$act" | jq -r '.info.ip // empty' 2>/dev/null)"
    fi
  fi
  if [ -z "$TARGET_IP" ] || [ "$TARGET_IP" = "null" ]; then
    echo "[htb] spawning $MACHINE_NAME (id $MACHINE_ID) ..."
    htb_spawn "$MACHINE_ID" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 40); do
      sleep 6
      local act; act="$(htb_active 2>/dev/null)"
      TARGET_IP="$(printf '%s' "$act" | jq -r '.info.ip // empty' 2>/dev/null)"
      [ -n "$TARGET_IP" ] && [ "$TARGET_IP" != "null" ] && break
    done
  fi
  [ -n "$TARGET_IP" ] && [ "$TARGET_IP" != "null" ] || { echo "[htb] no IP yet — spawn may still be booting; set it in target.env and re-run"; return 1; }
  echo "[htb] $MACHINE_NAME (id $MACHINE_ID) os=$OS_HINT diff=$DIFFICULTY ip=$TARGET_IP"
}

# Best-effort VPN routing to the target (non-fatal).
rc2_ensure_vpn() {
  local ip="$1" sudo_a="$2"
  ip route get "$ip" 2>/dev/null | grep -qE 'dev (tun|tap|ovpn)' && { echo "[vpn] $ip routed via tunnel"; return 0; }
  local ovpn="${HTB_OVPN:-}"; ovpn="${ovpn/#\~/$HOME}"
  if [ -n "$ovpn" ] && [ -f "$ovpn" ]; then
    echo "[vpn] connecting: $ovpn"
    $sudo_a openvpn --daemon --config "$ovpn" --log "$RUNDIR/logs/openvpn.log" 2>/dev/null || true
    local i; for i in $(seq 1 20); do sleep 1; ip route get "$ip" 2>/dev/null | grep -qE 'dev (tun|tap|ovpn)' && { echo "[vpn] tunnel up"; return 0; }; done
    echo "[vpn] started but no route yet — see $RUNDIR/logs/openvpn.log (a LAN target may not need VPN)"
  else
    echo "[vpn] no route and HTB_OVPN unset — connect manually if the target needs a tunnel: sudo openvpn <file> &"
  fi
}

# Scaffold the run dir + seed the three living-memory files. Sets global RUNDIR.
rc2_scaffold() {
  local slug; slug="$(printf '%s' "${MACHINE_NAME:-$TARGET_IP}" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_.-')"
  RUNDIR="$RC2_ROOT/runs/$slug"
  mkdir -p "$RUNDIR"/{recon,enum,loot/{hashes,keys,tickets,files},exploit,tools,bin,research,notes,logs/raw,tmp,.claude}
  # agents available to `claude -p` (cwd = run dir): symlink the team in.
  [ -e "$RUNDIR/.claude/agents" ] || ln -s "$RC2_ROOT/.claude/agents" "$RUNDIR/.claude/agents" 2>/dev/null || true
  # per-run hook registration (force-log every tool call + target-safety guard)
  local hook="$RC2_ROOT/lib/hook_log.sh"
  [ -s "$RUNDIR/.claude/settings.json" ] || cat > "$RUNDIR/.claude/settings.json" <<JSON
{
  "hooks": {
    "PreToolUse":  [ { "matcher": "", "hooks": [ { "type": "command", "command": "$hook pre" } ] } ],
    "PostToolUse": [ { "matcher": "", "hooks": [ { "type": "command", "command": "$hook post" } ] } ]
  }
}
JSON
  # sourceable facts
  cat > "$RUNDIR/target.env" <<ENV
# sourceable run facts
target_ip="$TARGET_IP"
machine_name="$MACHINE_NAME"
machine_id="$MACHINE_ID"
os_hint="$OS_HINT"
difficulty="$DIFFICULTY"
tmux_base="rc2_${slug}"
ENV
  # seed the three living files only if absent (so re-launch preserves memory = resume)
  [ -s "$RUNDIR/worldmodel.md" ] || cat > "$RUNDIR/worldmodel.md" <<MD
# World Model — ${MACHINE_NAME:-$TARGET_IP} ($TARGET_IP)
> Only DEMONSTRATED facts (each with a one-word provenance). Promote here after VERIFY.

## Access held
- (none yet)
## Credentials
- (none yet)
## Services & versions
- (unknown — enumerate)
## Hosts & topology
- target: $TARGET_IP  (os hint: ${OS_HINT:-unknown}, difficulty: ${DIFFICULTY:-unknown})
## Notable files/config
-
## Open questions
- What is the full exposed surface?
MD
  [ -s "$RUNDIR/hypotheses.md" ] || cat > "$RUNDIR/hypotheses.md" <<MD
# Hypotheses — ranked attack board
> One block per hypothesis. Re-rank every REFLECT. Keep refuted/frozen with the reason.

### H1: The exposed surface is unknown and must be mapped before any attack
- preconditions: network route to target
- evidence for: no enumeration done yet
- evidence against: —
- confidence: high   impact: enables all other hypotheses   cost: low
- next experiment: full-surface recon (all ports, then deep per-service enum); feed raw to recon-analyst
- budget: 0/4
MD
  [ -s "$RUNDIR/journal.md" ] || cat > "$RUNDIR/journal.md" <<MD
# Journal — append-only decision trail
$(date -u +%FT%TZ) START — target ${MACHINE_NAME:-$TARGET_IP} ($TARGET_IP). First pass: ORIENT says information is the bottleneck; open with full-surface enumeration.
MD
  : > "$RUNDIR/flags.txt" 2>/dev/null || true
  echo "$RUNDIR"
}
