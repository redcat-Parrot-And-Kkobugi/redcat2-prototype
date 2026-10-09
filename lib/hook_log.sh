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
ts="$(date +%Y%m%dT%H%M%S.%3N 2>/dev/null || date +%s)"

# Guarded = expensive/noisy target actions; exempt = shell listeners (re-run freely).
GUARD_RE='nmap|masscan|rustscan|gobuster|ffuf|feroxbuster|nikto|nuclei|wpscan|nxc |netexec|crackmapexec|evil-winrm| hydra|medusa|xfreerdp|kerbrute'
EXEMPT_RE='nc[^|]*-l|ncat[^|]*-l|socat.*(LISTEN| -l)|-l[vnp]{2,4}|msfconsole|multi/handler|rlwrap|pwncat'
RESF="$logdir/.cmd_results"
is_guarded(){ [ -n "$1" ] && ! printf '%s' "$1" | grep -qiE "$EXEMPT_RE" && printf '%s' "$1" | grep -qiE "$GUARD_RE"; }

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
exit 0
