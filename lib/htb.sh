#!/usr/bin/env bash
# =============================================================================
#  htb.sh — HTB orchestration: token liveness + HAR refresh, machine resolve/
#  spawn, VPN pre-flight, and the flag auto-submit watcher. Needs $RC2_ROOT and
#  the htb_api client sourced by rc2_load_env. Sourced via bootstrap.sh.
# =============================================================================

# Blocking watcher loop: submit each new hex flag in <rundir>/flags.txt via the HTB API, once.
# Needs machine_id + HTB_TOKEN + the sourced htb_api; returns immediately in IP-only mode.
# Stops when <rundir>/logs/.stop appears. Call it backgrounded from hunt:  rc2_flag_watcher "$R" &
rc2_flag_watcher() {
  local rundir="$1" seen="" line f resp
  [ "${RC2_HTB:-0}" = "1" ] && [ -n "${machine_id:-}" ] && [ -n "${HTB_TOKEN:-}" ] || return 0
  while :; do
    if [ -f "$rundir/flags.txt" ]; then
      while IFS= read -r line; do
        f="$(printf '%s' "$line" | grep -oiE "$RC2_FLAG_RE" | head -1)"; [ -n "$f" ] || continue
        case " $seen " in *" $f "*) continue;; esac
        seen="$seen $f"
        resp="$(htb_submit_flag "$machine_id" "$f" 2>/dev/null)"
        printf '%s submit %s -> %s\n' "$(date -u +%FT%TZ)" "$f" \
          "$(printf '%s' "$resp" | jq -rc '.message // .status // .' 2>/dev/null)" >> "$rundir/logs/flag_submit.log"
      done < "$rundir/flags.txt"
    fi
    [ -f "$rundir/logs/.stop" ] && break
    sleep 20
  done
}

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

# Best-effort VPN routing to the target (non-fatal). Needs $RUNDIR for the log path.
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
