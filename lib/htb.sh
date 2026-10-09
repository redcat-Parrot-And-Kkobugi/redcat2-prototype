#!/usr/bin/env bash
# =============================================================================
#  htb.sh — HTB orchestration: token liveness + HAR refresh, machine resolve/
#  spawn, VPN pre-flight, and the flag auto-submit watcher. Needs $RC2_ROOT and
#  the htb_api client sourced by rc2_load_env. Sourced via bootstrap.sh.
# =============================================================================

# _rc2_record_flag <rundir> <kind> <val> — idempotently write kind=flag into flags.txt
# (fill an empty "kind=" placeholder, else append). kind is user|root.
_rc2_record_flag() {
  local rundir="$1" kind="$2" val="$3" ft="$1/flags.txt"
  grep -qiE "^${kind}=${val}$" "$ft" 2>/dev/null && return 0
  if grep -qiE "^${kind}=" "$ft" 2>/dev/null; then sed -i "s/^${kind}=.*/${kind}=${val}/I" "$ft"
  else echo "${kind}=${val}" >> "$ft"; fi
}

# _rc2_submit_flag <rundir> <kind> <val> — submit once via the HTB API. Persistent dedup in
# logs/.submitted (survives watcher/hunt restarts); on an auth/invalid/expired response the kind
# is left UNMARKED so the next tick retries (e.g. after hunt refreshes the token). Needs machine_id.
_rc2_submit_flag() {
  local rundir="$1" kind="$2" val="$3" sub="$1/logs/.submitted" log="$1/logs/flag_submit.log"
  grep -qiE "^${kind}$" "$sub" 2>/dev/null && return 0
  local stamp resp msg; stamp="$(date -u +%FT%TZ)"
  resp="$(htb_submit_flag "$machine_id" "$val" 2>/dev/null)"
  msg="$(printf '%s' "$resp" | jq -r '.message // .status // .' 2>/dev/null | head -1)"
  printf '%s SUBMIT %s=%s id=%s -> %s\n' "$stamp" "$kind" "$val" "$machine_id" "${msg:-$resp}" >> "$log"
  case "$msg" in
    *nvalid*|*xpired*|*wrong*|*ncorrect*|*nauthenticated*|"") : ;;  # leave unmarked -> retry next tick
    *) echo "$kind" >> "$sub" ;;                                    # owned / already owned / accepted
  esac
}

# Blocking watcher loop: auto-submit user/root flags via the HTB API, through TWO channels —
#   1) manual:   user=/root= lines the agent writes to <rundir>/flags.txt
#   2) enforced: a logged command that read user.txt/root.txt (scanned from logs/tools.jsonl +
#                logs/raw/), so a flag is submitted even if the agent never updated flags.txt.
# Dedup is persistent (logs/.submitted), and a failed/auth-rejected submit retries next tick.
# Needs machine_id + HTB_TOKEN + the sourced htb_api; returns immediately in IP-only mode.
# Stops when <rundir>/logs/.stop appears. Call it backgrounded from hunt:  rc2_flag_watcher "$R" &
rc2_flag_watcher() {
  local rundir="$1" logs="$1/logs" hex='[0-9a-fA-F]{32}'
  [ "${RC2_HTB:-0}" = "1" ] && [ -n "${machine_id:-}" ] && [ -n "${HTB_TOKEN:-}" ] || return 0
  mkdir -p "$logs"; touch "$logs/.submitted"
  while :; do
    # 1) manual channel — flags.txt (user=/root=)
    if [ -f "$rundir/flags.txt" ]; then
      local u r
      u="$(grep -ioE "^user=$hex" "$rundir/flags.txt" 2>/dev/null | head -1 | cut -d= -f2)"
      r="$(grep -ioE "^root=$hex" "$rundir/flags.txt" 2>/dev/null | head -1 | cut -d= -f2)"
      [ -n "$u" ] && _rc2_submit_flag "$rundir" user "$u"
      [ -n "$r" ] && _rc2_submit_flag "$rundir" root "$r"
    fi
    # 2) enforced channel — a logged command that read user.txt/root.txt
    if [ -f "$logs/tools.jsonl" ]; then
      local line cmd of val
      while IFS= read -r line; do
        cmd="$(printf '%s' "$line" | jq -r 'select(.event=="post") | .command // empty' 2>/dev/null)"
        [ -n "$cmd" ] || continue
        case "$cmd" in
          *root.txt*) of="$(printf '%s' "$line" | jq -r '.out_file // empty' 2>/dev/null)"
                      val="$(grep -ioE "$hex" "$logs/$of" 2>/dev/null | head -1)"
                      [ -n "$val" ] && { _rc2_record_flag "$rundir" root "$val"; _rc2_submit_flag "$rundir" root "$val"; } ;;
          *user.txt*) of="$(printf '%s' "$line" | jq -r '.out_file // empty' 2>/dev/null)"
                      val="$(grep -ioE "$hex" "$logs/$of" 2>/dev/null | head -1)"
                      [ -n "$val" ] && { _rc2_record_flag "$rundir" user "$val"; _rc2_submit_flag "$rundir" user "$val"; } ;;
        esac
      done < "$logs/tools.jsonl"
    fi
    [ -f "$logs/.stop" ] && break
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
# Copy the newest *.har from the external capture dir ($HAR_SRC, default the Windows DevTools
# export folder) into redcat2/har/, if it's newer than what's already there. Keeps timestamps
# (cp -p) so "newest" stays consistent. No-op if the source dir / file is absent.
rc2_import_har() {
  local src="${HAR_SRC:-/mnt/c/Users/Godjs/Desktop/tmp/htb-api-har}"
  [ -d "$src" ] || { echo "[har] source dir not found: $src (skip import)"; return 0; }
  local newest; newest="$(ls -t "$src"/*.har 2>/dev/null | head -1)"
  [ -n "$newest" ] || { echo "[har] no *.har in $src (skip import)"; return 0; }
  mkdir -p "$RC2_ROOT/har" 2>/dev/null
  local dst="$RC2_ROOT/har/$(basename "$newest")"
  if [ -f "$dst" ] && [ ! "$newest" -nt "$dst" ]; then
    echo "[har] newest ($(basename "$newest")) already imported"
  else
    cp -p "$newest" "$dst" && echo "[har] imported newest HAR: $(basename "$newest")"
  fi
}

rc2_ensure_htb_token() {
  if [ "${RC2_HTB:-0}" != "1" ]; then echo "[token] scripts/lib/htb_api.sh missing — IP-only mode"; return 1; fi
  if _rc2_token_live; then echo "[token] HTB token OK (live auth)"; return 0; fi
  rc2_import_har                                   # pull the freshest HAR from the capture dir first
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
    # poll for the IP: 15 tries, 3 min apart (= 45 min total). Tune via env.
    local i tries="${IP_WAIT_TRIES:-15}" interval="${IP_WAIT_INTERVAL:-180}"
    for i in $(seq 1 "$tries"); do
      local act; act="$(htb_active 2>/dev/null)"
      TARGET_IP="$(printf '%s' "$act" | jq -r '.info.ip // empty' 2>/dev/null)"
      [ -n "$TARGET_IP" ] && [ "$TARGET_IP" != "null" ] && break
      echo "[htb] waiting for IP ... (${i}/${tries}, next check in ${interval}s)"
      sleep "$interval"
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
