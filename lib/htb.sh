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
  grep -qiE "^${kind}$" "$sub" 2>/dev/null && return 0              # this kind already owned/accepted
  grep -qiE "^${kind}:bad:${val}$" "$sub" 2>/dev/null && return 0   # this exact value already rejected — don't hammer the API
  local stamp resp msg; stamp="$(rc2_utc)"
  resp="$(htb_submit_flag "$machine_id" "$val" 2>/dev/null)"
  msg="$(printf '%s' "$resp" | jq -r '.message // .status // .' 2>/dev/null | head -1)"
  printf '%s SUBMIT %s=%s id=%s -> %s\n' "$stamp" "$kind" "$val" "$machine_id" "${msg:-$resp}" >> "$log"
  case "$msg" in
    *xpired*|*nauthenticated*|"") : ;;                               # TOKEN issue -> retry next tick (unmarked)
    *ncorrect*|*nvalid*|*wrong*)  echo "${kind}:bad:${val}" >> "$sub" ;;  # WRONG VALUE -> stop resubmitting it; a new value (e.g. after a reset) still tries
    *) echo "$kind" >> "$sub" ;;                                     # owned / already owned / accepted -> done
  esac
}

# rc2_htb_owned_init <rundir> — at launch, read the machine's owned status from the HTB profile and set
# logs/.flag_mode: "live" if the API exposes ownership (any already-owned flag is pre-marked so it is
# never submitted), else "defer" (record flags during the run but submit only once, in the final sweep).
# Best-effort: no API/token -> defer. Field spellings vary by API version, so it probes several.
rc2_htb_owned_init() {
  local rundir="$1" logs="$1/logs"; mkdir -p "$logs"; touch "$logs/.submitted" 2>/dev/null
  [ "${RC2_HTB:-0}" = "1" ] && [ -n "${machine_id:-}" ] && [ -n "${HTB_TOKEN:-}" ] || { echo defer > "$logs/.flag_mode" 2>/dev/null; return 0; }
  local prof uo ro; prof="$(htb_machine_profile "${machine_id:-$machine_name}" 2>/dev/null)"
  uo="$(printf '%s' "$prof" | jq -r '[.info.authUserInUserOwns,.authUserInUserOwns,.info.isUserOwned,.info.userOwned,.info.user_owned]|map(select(.!=null))|.[0] // empty' 2>/dev/null)"
  ro="$(printf '%s' "$prof" | jq -r '[.info.authUserInRootOwns,.authUserInRootOwns,.info.isRootOwned,.info.rootOwned,.info.root_owned]|map(select(.!=null))|.[0] // empty' 2>/dev/null)"
  _rc2_owned(){ case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in true|1|yes) return 0;; *) return 1;; esac; }
  if [ -n "$uo" ] || [ -n "$ro" ]; then
    echo live > "$logs/.flag_mode"
    _rc2_owned "$uo" && ! grep -qiE '^user$' "$logs/.submitted" 2>/dev/null && { echo user >> "$logs/.submitted"; printf '%s OWNED-AT-START user (skip submit)\n' "$(rc2_utc)" >> "$logs/flag_submit.log"; }
    _rc2_owned "$ro" && ! grep -qiE '^root$' "$logs/.submitted" 2>/dev/null && { echo root >> "$logs/.submitted"; printf '%s OWNED-AT-START root (skip submit)\n' "$(rc2_utc)" >> "$logs/flag_submit.log"; }
    echo "[flags] HTB owned-at-start: user=${uo:-?} root=${ro:-?} — live submit for the rest"
  else
    echo defer > "$logs/.flag_mode"
    echo "[flags] HTB profile exposes no owned-status field — recording during the run, submitting once at the end"
  fi
}

# rc2_flag_scan_once <rundir> — ONE pass of both submit channels; submit any new user/root flag.
# Safe no-op without machine_id+HTB_TOKEN (IP-only). Idempotent via logs/.submitted, so it is safe
# to call both from the watcher loop and from hunt's cleanup (the final sweep).
#   1) manual:   user=/root= lines the agent writes to <rundir>/flags.txt
#   2) enforced: a logged command that read user.txt/root.txt (from logs/tools.jsonl + logs/raw/),
#                so a flag is submitted even if the agent never updated flags.txt.
rc2_flag_scan_once() {
  local rundir="$1" final="${2:-}" logs="$1/logs"
  [ "${RC2_HTB:-0}" = "1" ] && [ -n "${machine_id:-}" ] && [ -n "${HTB_TOKEN:-}" ] || return 0
  mkdir -p "$logs"; touch "$logs/.submitted"
  # defer mode (HTB didn't expose owned-status): RECORD every tick but SUBMIT only in the final sweep.
  local mode do_submit=1; mode="$(cat "$logs/.flag_mode" 2>/dev/null)"; mode="${mode:-live}"
  [ "$mode" = "defer" ] && [ "$final" != "final" ] && do_submit=0
  # 1) manual channel — flags.txt (user=/root=)
  local u r
  u="$(rc2_flag_value user "$rundir")"; [ -n "$u" ] && [ "$do_submit" = 1 ] && _rc2_submit_flag "$rundir" user "$u"
  r="$(rc2_flag_value root "$rundir")"; [ -n "$r" ] && [ "$do_submit" = 1 ] && _rc2_submit_flag "$rundir" root "$r"
  # 2) enforced channel — a logged command that read user.txt/root.txt (RECORD always; SUBMIT per mode)
  local line cmd of val
  rc2_tl_posts "$logs/tools.jsonl" | while IFS= read -r line; do
    cmd="$(printf '%s' "$line" | jq -r '.command // empty' 2>/dev/null)"
    [ -n "$cmd" ] || continue
    case "$cmd" in
      *root.txt*) of="$(printf '%s' "$line" | jq -r '.out_file // empty' 2>/dev/null)"
                  val="$(rc2_hex_in "$logs/$of")"
                  [ -n "$val" ] && { _rc2_record_flag "$rundir" root "$val"; [ "$do_submit" = 1 ] && _rc2_submit_flag "$rundir" root "$val"; } ;;
      *user.txt*) of="$(printf '%s' "$line" | jq -r '.out_file // empty' 2>/dev/null)"
                  val="$(rc2_hex_in "$logs/$of")"
                  [ -n "$val" ] && { _rc2_record_flag "$rundir" user "$val"; [ "$do_submit" = 1 ] && _rc2_submit_flag "$rundir" user "$val"; } ;;
    esac
  done
}

# Blocking watcher loop: scan both channels every FLAG_INTERVAL s (default 300 = 5 min). hunt also
# runs a final rc2_flag_scan_once at cleanup, so a flag captured AFTER the last poll (e.g. root read
# in the final minutes) is still submitted regardless of the interval.
# Needs machine_id + HTB_TOKEN; returns immediately in IP-only mode. Stops on <rundir>/logs/.stop.
# Call it backgrounded from hunt:  rc2_flag_watcher "$R" &
rc2_flag_watcher() {
  local rundir="$1" logs="$1/logs" iv="${FLAG_INTERVAL:-300}"
  [ "${RC2_HTB:-0}" = "1" ] && [ -n "${machine_id:-}" ] && [ -n "${HTB_TOKEN:-}" ] || return 0
  while :; do
    rc2_flag_scan_once "$rundir"
    [ -f "$logs/.stop" ] && break
    sleep "$iv"
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
# --- VPN pre-flight helpers --------------------------------------------------
# _rc2_vpn_running_cfg — the --config path of the running openvpn (first found), via /proc so no
# pkill-style pattern can match this shell; empty if none is running.
_rc2_vpn_running_cfg() {
  local pid cfg
  for pid in $(pgrep -x openvpn 2>/dev/null); do
    cfg="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk 'take{print; exit} $0=="--config"{take=1}')"
    [ -n "$cfg" ] && { printf '%s\n' "$cfg"; return 0; }
  done
  return 1
}
# _rc2_target_reachable <ip> — classify a ROUTED target: ok | wrong-server | unknown.
# "wrong-server" = gateway returns ICMP host-unreachable (the host isn't on this VPN's segment);
# "unknown" = silent timeout (may just be booting, or ICMP-filtered-but-up); "ok" = replies.
_rc2_target_reachable() {
  local out; out="$(ping -c2 -W2 "$1" 2>&1)"
  printf '%s' "$out" | grep -qiE 'bytes from'  && { echo ok;           return; }
  printf '%s' "$out" | grep -qiE 'unreachable' && { echo wrong-server; return; }
  echo unknown
}
# _rc2_vpn_swap <ovpn> <sudo_a> <ip> — tear down any openvpn and connect <ovpn> (VPN_AUTOFIX path).
_rc2_vpn_swap() {
  local ovpn="$1" sudo_a="$2" ip="$3" p i
  echo "[vpn] VPN_AUTOFIX=1 → reconnecting to $(basename "$ovpn")"
  for p in $(pgrep -x openvpn 2>/dev/null); do $sudo_a kill "$p" 2>/dev/null; done
  sleep 3
  $sudo_a openvpn --daemon --config "$ovpn" --log "$RUNDIR/logs/openvpn.log" 2>/dev/null || true
  for i in $(seq 1 20); do sleep 1; ip route get "$ip" 2>/dev/null | grep -qE 'dev (tun|tap|ovpn)' && break; done
}

rc2_ensure_vpn() {
  local ip="$1" sudo_a="$2"
  local ovpn="${HTB_OVPN:-}"; ovpn="${ovpn/#\~/$HOME}"

  # (A) config-mismatch: a DIFFERENT openvpn is running than HTB_OVPN → wrong server. Warn (opt-in autofix).
  if [ -n "$ovpn" ]; then
    local running; running="$(_rc2_vpn_running_cfg || true)"
    if [ -n "$running" ] && [ "$(basename "$running")" != "$(basename "$ovpn")" ]; then
      echo "${y:-}[vpn] WARNING: openvpn is running '$(basename "$running")' but HTB_OVPN='$(basename "$ovpn")' — likely the WRONG server; the target lives on the HTB_OVPN server. (VPN_AUTOFIX=1 to auto-reconnect.)${n:-}"
      [ "${VPN_AUTOFIX:-0}" = "1" ] && [ -f "$ovpn" ] && _rc2_vpn_swap "$ovpn" "$sudo_a" "$ip"
    fi
  fi

  # (B) route present?
  if ip route get "$ip" 2>/dev/null | grep -qE 'dev (tun|tap|ovpn)'; then
    echo "[vpn] $ip routed via tunnel"
    # (C) routed ≠ reachable — actually probe the target (this is what catches the wrong-server case)
    case "$(_rc2_target_reachable "$ip")" in
      ok)           echo "[vpn] $ip reachable ✓" ;;
      wrong-server) echo "${r:-}[vpn] WARNING: $ip routes via the tunnel but the gateway returns host-unreachable — you are almost certainly on the WRONG VPN server/region (the machine lives elsewhere). Check your .ovpn / HTB panel; set VPN_AUTOFIX=1 (with HTB_OVPN) to auto-reconnect.${n:-}"
                    if [ "${VPN_AUTOFIX:-0}" = "1" ] && [ -f "$ovpn" ]; then _rc2_vpn_swap "$ovpn" "$sudo_a" "$ip"; echo "[vpn] after autofix: $(_rc2_target_reachable "$ip")"; fi ;;
      unknown)      echo "[vpn] $ip not answering yet (may be booting; if it persists you may be on the wrong VPN server)" ;;
    esac
    return 0
  fi

  # (D) no route → connect HTB_OVPN (as before)
  if [ -n "$ovpn" ] && [ -f "$ovpn" ]; then
    echo "[vpn] connecting: $ovpn"
    $sudo_a openvpn --daemon --config "$ovpn" --log "$RUNDIR/logs/openvpn.log" 2>/dev/null || true
    local i; for i in $(seq 1 20); do sleep 1; ip route get "$ip" 2>/dev/null | grep -qE 'dev (tun|tap|ovpn)' && { echo "[vpn] tunnel up"; echo "[vpn] $ip: $(_rc2_target_reachable "$ip")"; return 0; }; done
    echo "[vpn] started but no route yet — see $RUNDIR/logs/openvpn.log (a LAN target may not need VPN)"
  else
    echo "[vpn] no route and HTB_OVPN unset — connect manually if the target needs a tunnel: sudo openvpn <file> &"
  fi
}
