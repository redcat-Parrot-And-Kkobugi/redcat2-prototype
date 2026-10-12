#!/usr/bin/env bash
# =============================================================================
#  hook_log.sh — Claude Code PreToolUse/PostToolUse hook for redcat2.
#  Force-logs EVERY tool call + full result, independent of model behavior, and
#  guards the target against identical-command/identical-result repeats (stuck/
#  throttle/DoS). Registered per-run in <run>/.claude/settings.json by bootstrap.sh.
#    pre:  logs tool_input inline to logs/tools.jsonl; may block (exit 2) a repeat.
#    post: dumps full result to logs/raw/<ts>.out, indexes it in tools.jsonl.
#  Always exits 0 on post so logging never alters the hunt. Hook JSON on stdin.
# =============================================================================
phase="${1:-post}"
input="$(cat)"

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
logdir="$cwd/logs"; mkdir -p "$logdir/raw" 2>/dev/null
jsonl="$logdir/tools.jsonl"
ts="$(date -u +%Y%m%dT%H%M%S.%3N 2>/dev/null || date +%s)"   # UTC, to match status.md / analyze / journal

# Guarded = expensive/noisy target actions; exempt = shell listeners (re-run freely).
GUARD_RE='nmap|masscan|rustscan|gobuster|ffuf|feroxbuster|nikto|nuclei|wpscan|nxc |netexec|crackmapexec|evil-winrm| hydra|medusa|xfreerdp|kerbrute'
EXEMPT_RE='nc[^|]*-l|ncat[^|]*-l|socat.*(LISTEN| -l)|-l[vnp]{2,4}|msfconsole|multi/handler|rlwrap|pwncat'
RESF="$logdir/.cmd_results"
is_guarded(){ [ -n "$1" ] && ! printf '%s' "$1" | grep -qiE "$EXEMPT_RE" && printf '%s' "$1" | grep -qiE "$GUARD_RE"; }

# ── P1: rabbit-hole accounting + guard ───────────────────────────────────────
# Accounting (counters in logs/accounting.json) is ALWAYS written — cheap, fail-open — so WARN
# thresholds can be calibrated. Gating (warn/block) is opt-in: RC2_GUARD=off (default) | warn | block.
# This is the "accounting" half of the intent/accounting split: the agent owns ledger.json, the hook
# owns accounting.json and never trusts the agent's hand-written JSON for its counters.
# Effective guard mode = the STRONGER of two tiers: the operator's FLOOR (RC2_GUARD env — the solver
# and the supervisor cannot go below it) and the supervisor's LIVE level (logs/guard.mode, honoured
# only if its tag matches logs/.guard_secret, a dotfile the solver is forbidden to read). off<warn<block.
_mode_rank(){ case "$1" in block) echo 3;; warn) echo 2;; *) echo 1;; esac; }
rc2_effective_guard(){
  local floor="${RC2_GUARD:-off}" live="off" gm="$logdir/guard.mode" sec="$logdir/.guard_secret" m t want
  case "$floor" in off|warn|block) ;; *) floor=off;; esac
  if [ -s "$gm" ] && [ -s "$sec" ]; then
    m="$(sed -n 's/^mode=//p' "$gm" 2>/dev/null | head -1 | tr -cd 'a-z')"
    t="$(sed -n 's/^tag=//p'  "$gm" 2>/dev/null | head -1 | tr -cd '0-9a-f')"
    want="$(printf '%s%s' "$m" "$(cat "$sec" 2>/dev/null)" | md5sum 2>/dev/null | cut -c1-32)"
    [ -n "$m" ] && [ -n "$t" ] && [ "$t" = "$want" ] && case "$m" in off|warn|block) live="$m";; esac
  fi
  if [ "$(_mode_rank "$live")" -gt "$(_mode_rank "$floor")" ]; then echo "$live"; else echo "$floor"; fi
}
GUARD_MODE="$(rc2_effective_guard)"
LEDGER="$cwd/ledger.json"
ACCT="$logdir/accounting.json"
REPEAT_FREEZE="${RC2_REPEAT_FREEZE:-4}"

# rc2_fp <input-json> — a conservative "shape" of this call: same target action with a different
# payload hashes the same (so a reworded retry counts as a repeat), but a different command/tool/
# approach hashes differently (so genuine variation is NOT counted). The sonnet sameness-judge (next
# sub-phase) refines the hard cases; this is the cheap per-call proxy.
rc2_fp() {
  local ip tool cmd body
  ip="$( [ -f "$cwd/target.env" ] && . "$cwd/target.env" 2>/dev/null; printf '%s' "${target_ip:-}")"
  tool="$(printf '%s' "$1" | jq -r '.tool_name // "?"' 2>/dev/null)"
  cmd="$(printf '%s' "$1" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  if [ -n "$cmd" ]; then
    body="$(printf '%s' "$cmd" | tr -s ' \t\n' ' ')"
    [ -n "$ip" ] && body="$(printf '%s' "$body" | sed "s/${ip//./\\.}/IP/g" 2>/dev/null)"
    body="$(printf '%s' "$body" | sed 's/[0-9a-fA-F]\{8,\}/HEX/g' 2>/dev/null | cut -c1-200)"
  else
    body="$(printf '%s' "$1" | jq -rc '.tool_input' 2>/dev/null | cut -c1-200)"
  fi
  printf '%s|%s' "$tool" "$body" | md5sum | cut -c1-16
}

# rc2_guard_msg <reason> <hypo> <exp> <ceil> <rep> — structured message to the agent (point 7: echoes
# the action it was about to take + the ledger snapshot + the concrete alternatives).
rc2_guard_msg() {
  local bc; bc="$(printf '%s' "$input" | jq -r '.tool_input.command // (.tool_name) // "?"' 2>/dev/null | tr -s ' \t\n' ' ' | cut -c1-160)"
  {
    echo "redcat2 guard [$GUARD_MODE]: $1."
    echo "  ledger: current=$2  experiments=$3/$4  repeat_on_$2=$5   (solved runs here finished in ~186-416 calls)"
    echo "  you were about to run: $bc"
    echo "  DO ONE OF: (a) a MATERIALLY different attempt — new vector/tool/assumption, not a reworded retry;"
    echo "     (b) FREEZE $2: in ledger.json set .hypotheses.$2.freeze.frozen=true with an honest confidence + one-line reason, then switch to another hypothesis;"
    echo "     (c) only if you are sure this path is right: set .override={\"hypothesis\":\"$2\",\"reason\":\"<why this, not a switch>\",\"nonce\":\"<unique>\"} in ledger.json to proceed ONCE (it is consumed and logged; repeats escalate)."
  } >&2
}

# rc2_guard_pre — always updates accounting; when RC2_GUARD!=off, may warn (exit 0) or block (return 2).
rc2_guard_pre() {
  [ -s "$LEDGER" ] && [ -s "$ACCT" ] || return 0        # ledger-based model not in use -> no-op
  local cur frozen fp exp ceil warn last_fp prev_rep new_rep
  cur="$(jq -r '.current_hypothesis // empty' "$LEDGER" 2>/dev/null)"; [ -n "$cur" ] || cur="unassigned"
  frozen="$(jq -r --arg h "$cur" '.hypotheses[$h].freeze.frozen // false' "$LEDGER" 2>/dev/null)"
  # an arbiter freeze (set by the independent judge, in the hook-owned accounting file) also counts and
  # the solver cannot clear it by editing its own ledger.json
  [ "$frozen" = "true" ] || { [ -n "$(jq -r --arg h "$cur" '.arbiter_freezes[$h] // empty' "$ACCT" 2>/dev/null)" ] && frozen=true; }
  fp="$(rc2_fp "$input")"
  exp="$(jq -r '.global.experiments // 0' "$ACCT" 2>/dev/null)"
  ceil="$(jq -r '.global.ceiling // 999999' "$ACCT" 2>/dev/null)"
  warn="$(jq -r '.global.warn_at // 999999' "$ACCT" 2>/dev/null)"
  last_fp="$(jq -r --arg h "$cur" '.per_hypothesis[$h].last_action_fp // empty' "$ACCT" 2>/dev/null)"
  prev_rep="$(jq -r --arg h "$cur" '.per_hypothesis[$h].repeat_count // 0' "$ACCT" 2>/dev/null)"
  if [ "$fp" = "$last_fp" ]; then new_rep=$((prev_rep+1)); else new_rep=1; fi

  if [ "$GUARD_MODE" != "off" ]; then
    local reason="" blocked=""
    if [ "$frozen" = "true" ]; then reason="current hypothesis $cur is FROZEN — do not keep working it"; blocked=1
    elif [ "$new_rep" -ge "$REPEAT_FREEZE" ] 2>/dev/null; then reason="the same action repeated ${new_rep}x on $cur with no meaningful variation"; blocked=1
    elif [ "$exp" -ge "$ceil" ] 2>/dev/null; then reason="global experiment ceiling reached ($exp/$ceil)"; blocked=1; fi

    if [ -n "$blocked" ]; then
      local ov_h ov_nonce ov_reason consumed
      ov_h="$(jq -r '.override.hypothesis // empty' "$LEDGER" 2>/dev/null)"
      ov_nonce="$(jq -r '.override.nonce // empty' "$LEDGER" 2>/dev/null)"
      ov_reason="$(jq -r '.override.reason // empty' "$LEDGER" 2>/dev/null)"
      consumed="$(jq -r --arg n "$ov_nonce" '.consumed_overrides // [] | index($n)' "$ACCT" 2>/dev/null)"
      if [ -n "$ov_nonce" ] && [ "$ov_h" = "$cur" ] && [ "$consumed" = "null" ]; then
        jq --arg n "$ov_nonce" '.consumed_overrides=((.consumed_overrides // [])+[$n]) | .global.overrides_used=((.global.overrides_used // 0)+1)' "$ACCT" > "$ACCT.tmp" 2>/dev/null && mv "$ACCT.tmp" "$ACCT" 2>/dev/null
        echo "redcat2 guard: OVERRIDE consumed for $cur (reason: ${ov_reason:-none}) — allowed ONCE. [$reason] Repeated overrides on $cur will require arbiter sign-off." >&2
      else
        rc2_guard_msg "$reason" "$cur" "$exp" "$ceil" "$new_rep"
        if [ "$GUARD_MODE" = "block" ]; then
          jq --arg h "$cur" '.freeze_candidate={hypothesis:$h, reason:"repeat/stall/frozen", at:(now|todate)}' "$ACCT" > "$ACCT.tmp" 2>/dev/null && mv "$ACCT.tmp" "$ACCT" 2>/dev/null
          return 2
        fi
      fi
    elif [ "$exp" -ge "$warn" ] 2>/dev/null; then
      echo "redcat2 guard (warn): $exp experiments (warn@$warn, ceiling $ceil). If worldmodel.md isn't gaining facts, zoom out and re-rank hypotheses." >&2
    fi
  fi

  jq --arg h "$cur" --arg fp "$fp" \
     '.global.experiments=((.global.experiments // 0)+1)
      | .per_hypothesis[$h]=((.per_hypothesis[$h] // {spent:0,repeat_count:0})
          | .spent=((.spent // 0)+1)
          | .repeat_count=(if (.last_action_fp // "")==$fp then ((.repeat_count // 0)+1) else 1 end)
          | .last_action_fp=$fp | .last_utc=(now|todate))
      | .updated_utc=(now|todate)' \
     "$ACCT" > "$ACCT.tmp" 2>/dev/null && mv "$ACCT.tmp" "$ACCT" 2>/dev/null
  return 0
}

if [ "$phase" = "pre" ]; then
  printf '%s' "$input" | jq -c --arg ts "$ts" \
      '{ts:$ts, event:"pre", tool:(.tool_name // "?"),
        command:(.tool_input.command // null), input:.tool_input}' \
      >> "$jsonl" 2>/dev/null
  cmd="$(printf '%s' "$input" | jq -r 'select(.tool_name=="Bash") | .tool_input.command // empty' 2>/dev/null)"
  if is_guarded "$cmd"; then
    ch="$(printf '%s' "$cmd" | tr -s ' \t' ' ' | md5sum | cut -c1-16)"
    consec="$(awk -v c="$ch" '$1==c{print $3}' "$RESF" 2>/dev/null)"; consec="${consec:-0}"
    lim="${REDCAT_REPEAT_LIMIT:-2}"
    if [ "$consec" -ge "$lim" ] 2>/dev/null; then
      echo "redcat2 target-safety: this EXACT command already returned the SAME result ${consec}x — BLOCKED. Re-running just repeats it (target may be stuck/throttled). Read the existing result in logs/raw/, change the approach, or try a different vector. Respawn is the LAST resort, only if the target is confirmed broken." >&2
      exit 2
    fi
  fi

  # integrity: block a lookup of THIS box's OWN public solution (htb + machine_name + spoiler keyword).
  # Narrow on purpose — all three required — so common-word box names don't false-positive; the broad
  # spirit ("don't look up how this box is solved") lives in doctrine 00 → No spoilers. Fail-open.
  q="$(printf '%s' "$input" | jq -r 'select(.tool_name=="WebSearch" or .tool_name=="WebFetch") | [(.tool_input.query // ""),(.tool_input.url // ""),(.tool_input.prompt // "")] | join(" ")' 2>/dev/null)"
  if [ -n "$q" ]; then
    local_mn="$( [ -f "$cwd/target.env" ] && . "$cwd/target.env" 2>/dev/null; printf '%s' "${machine_name:-}")"
    if [ -n "$local_mn" ] \
       && printf '%s' "$q" | grep -qiw 'htb' \
       && printf '%s' "$q" | grep -qiwF "$local_mn" \
       && printf '%s' "$q" | grep -qiE 'writeup|walkthrough|solution|guide|공략'; then
      echo "redcat2 integrity: looking up this box's public solution is forbidden (htb + '$local_mn' + writeup/walkthrough/solution/guide). Research the technique/CVE/product instead — not how this box is solved. (doctrine 00 → No spoilers)" >&2
      exit 2
    fi
  fi

  # P1: rabbit-hole accounting (always) + guard (opt-in). Fail-open; only a block returns 2.
  rc2_guard_pre; grc=$?; [ "${grc:-0}" -eq 2 ] && exit 2
  exit 0
fi

# post: full result to its own file, indexed in tools.jsonl
outfile="raw/${ts}_$$.out"
printf '%s' "$input" \
  | jq -r '.tool_response
            | if type=="string" then .
              elif type=="object" then ((.stdout // "") + (.stderr // "")) as $s
                   | (if ($s|length)>0 then $s else tojson end)
              else tostring end' \
  > "$logdir/$outfile" 2>/dev/null
[ -s "$logdir/$outfile" ] || printf '%s' "$input" | jq -c '.tool_response' > "$logdir/$outfile" 2>/dev/null
bytes="$(wc -c < "$logdir/$outfile" 2>/dev/null | tr -d ' ')"

rcmd="$(printf '%s' "$input" | jq -r 'select(.tool_name=="Bash") | .tool_input.command // empty' 2>/dev/null)"
if is_guarded "$rcmd"; then
  ch="$(printf '%s' "$rcmd" | tr -s ' \t' ' ' | md5sum | cut -c1-16)"
  rh="$(md5sum "$logdir/$outfile" 2>/dev/null | cut -c1-16)"
  prev="$(awk -v c="$ch" '$1==c{print $2"|"$3}' "$RESF" 2>/dev/null)"; prh="${prev%%|*}"; pc="${prev##*|}"; pc="${pc:-0}"
  if [ -n "$rh" ] && [ "$rh" = "$prh" ]; then nconsec=$((pc+1)); else nconsec=1; fi
  { grep -vE "^$ch " "$RESF" 2>/dev/null; echo "$ch $rh $nconsec"; } > "$RESF.tmp" 2>/dev/null && mv "$RESF.tmp" "$RESF" 2>/dev/null
fi

printf '%s' "$input" | jq -c --arg ts "$ts" --arg of "$outfile" --arg b "${bytes:-0}" \
    '{ts:$ts, event:"post", tool:(.tool_name // "?"), command:(.tool_input.command // null),
      duration_ms:(.duration_ms // null),
      exit:(.tool_response.exit_code // .tool_response.returncode // null),
      out_bytes:($b|tonumber), out_file:$of}' \
  >> "$jsonl" 2>/dev/null

# P1 progress signal: did worldmodel.md gain content since the last recorded fact-change? If so,
# stamp progress (resets the stall clock the guard/analysis read). Cheap hash; fail-open.
if [ -s "$ACCT" ] && [ -f "$cwd/worldmodel.md" ]; then
  wmfp="$(md5sum "$cwd/worldmodel.md" 2>/dev/null | cut -c1-16)"
  pfp="$(jq -r '.progress.last_progress_fp // empty' "$ACCT" 2>/dev/null)"
  if [ -n "$wmfp" ] && [ "$wmfp" != "$pfp" ]; then
    jq --arg f "$wmfp" '.progress.last_progress_fp=$f | .progress.last_progress_utc=(now|todate) | .progress.last_progress_experiment=(.global.experiments // 0) | .progress.stale_ticks=0' "$ACCT" > "$ACCT.tmp" 2>/dev/null && mv "$ACCT.tmp" "$ACCT" 2>/dev/null
  fi
fi
exit 0
