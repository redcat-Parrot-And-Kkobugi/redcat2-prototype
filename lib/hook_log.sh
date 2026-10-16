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
# shared guard/JSON helpers (dependency-free; guarded so a missing/broken lib never breaks the hook)
. "$(dirname "$0")/guard_lib.sh" 2>/dev/null || true
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
# effective mode = floor(RC2_GUARD env) ⊔ live(logs/guard.mode, tag-checked); see guard_lib.sh
GUARD_MODE="$(rc2_guard_effective "$cwd")"
LEDGER="$cwd/ledger.json"
ACCT="$logdir/accounting.json"
REPEAT_FREEZE="${RC2_REPEAT_FREEZE:-4}"   # default lives in env.sh; this is the detached-hook fallback

# rc2_fp <input-json> — a conservative "shape" of this call for LITERAL-repeat detection only: a
# reworded/re-payloaded retry of the same command hashes the same, a different command/tool hashes
# differently. This is deliberately NOT the semantic sameness signal — judging whether textually-varied
# or Task-delegated work is "the same disproven approach" is done out-of-band by the sonnet/haiku judge
# (rc2_guard_watcher, stall-triggered, fingerprint-independent). Per-call model calls are not viable in
# the hook (cost + latency on every action), so the hook stays cheap and the judge does the thinking.
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

# _hook_surface <command> — a DOMAIN-AGNOSTIC surface label, so accounting can flag a lopsided effort
# distribution (one surface hammered 200x while another got 1 glance = an under-explored surface the
# surrender gate should re-open). Deliberately names NO product or box — the old version hardcoded one
# box's AWS services (codebuild/ecs/lambda/sqs…) so every non-cloud box collapsed to "other" and the
# signal died. Now two structural parts:
#   family  — tool/protocol class, scanned over the whole command so it still classifies actions wrapped
#             in sudo/tmux/ssh: scan|web|smb|ad|db|ssh|cred|cloud|exploit|other.
#   target  — the host:port / URL authority / IP / port the action hits; for a cloud CLI, the SERVICE
#             subcommand (`aws <service>`, `kubectl <resource>`) read straight from the command, so cloud
#             services differentiate structurally (cloud@codebuild vs cloud@s3) with no hardcoded taxonomy.
# label = "family@target" (or just "family" when no target is visible). Best-effort; unknown -> "other".
_hook_surface() {
  local c; c="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  [ -z "$c" ] && { echo other; return; }
  local L="" tgt=""
  # Independent matches (NOT elif): an action collects EVERY label that fits = a multi-DIMENSIONAL
  # surface (service it talks to · phase · observable technique). This is still a hardcoded, domain-general
  # catalog (no box/product names), but multi-label + a tool-name fallback (never a bare "other") keep the
  # signal alive on any box. Inferred/semantic labels (privesc-candidate, …) are NOT here — they are the
  # opt-in out-of-band Tier-2 labeler (scripts/surface_label.sh).
  # ── service (what it talks to) ──
  printf '%s' "$c" | grep -qE 'curl|wget|(^|[^a-z])http|(^|[^a-z])nc |ncat|websocat|nikto|whatweb|wpscan|gobuster|ffuf|feroxbuster' && L="$L web"
  printf '%s' "$c" | grep -qE 'smbclient|smbmap|crackmapexec|(^|[^a-z])nxc |netexec|rpcclient|impacket|psexec|wmiexec|smbexec|enum4linux|:445|\\\\[0-9a-z]' && L="$L smb"
  printf '%s' "$c" | grep -qE 'ldapsearch|bloodhound|ldapdomaindump|ldap://|(^|[^a-z])dc=[a-z]' && L="$L ad"
  printf '%s' "$c" | grep -qE 'kerbrute|getuserspns|getnpusers|gettgt|getst|(^|[^a-z])kinit|krb5|\.kirbi|\.ccache' && L="$L kerberos"
  printf '%s' "$c" | grep -qE 'mysql|psql|mariadb|mssql|sqsh|sqlcmd|(^|[^a-z])mongo|sqlmap|jdbc:|:3306|:5432|:1433|:27017' && L="$L db"
  printf '%s' "$c" | grep -qE 'redis-cli|:6379' && L="$L redis"
  printf '%s' "$c" | grep -qE '(^|[^a-z])ssh |sshpass|(^|[^a-z])scp |ssh-keygen|authorized_keys|id_rsa|id_ed25519' && L="$L ssh"
  printf '%s' "$c" | grep -qE '(^|[^a-z])ftp |lftp|:21( |$)' && L="$L ftp"
  printf '%s' "$c" | grep -qE '(^|[^a-z])dig |nslookup|dnsenum|dnsrecon|:53( |$)' && L="$L dns"
  printf '%s' "$c" | grep -qE 'snmpwalk|snmp-check|onesixtyone|:161' && L="$L snmp"
  printf '%s' "$c" | grep -qE 'showmount|(^|[^a-z])nfs|:2049' && L="$L nfs"
  printf '%s' "$c" | grep -qE '(^|[^a-z])smtp|:25( |$)|:587|swaks' && L="$L mail"
  printf '%s' "$c" | grep -qE '(^|[^a-z])aws |gcloud|(^|[^a-z])az |kubectl|(^|[^a-z])oc |doctl|boto3|localstack|:4566' && L="$L cloud"
  printf '%s' "$c" | grep -qE '(^|[^a-z])docker |containerd|(^|[^a-z])runc|/var/run/docker|kubelet|/proc/1/|capsh' && L="$L container"
  # ── action / phase ──
  printf '%s' "$c" | grep -qE 'nmap|masscan|rustscan|-p-|--top-ports|(^|[^a-z])-sv|(^|[^a-z])-sc' && L="$L scan"
  printf '%s' "$c" | grep -qE 'gobuster|ffuf|feroxbuster|dirb|dirsearch|wfuzz|(^|[^a-z])fuzz|seclists|wordlist' && L="$L enum"
  printf '%s' "$c" | grep -qE 'hydra|medusa|patator|(^|[^a-z])-P [^ ]|(^|[^a-z])brute' && L="$L brute"
  printf '%s' "$c" | grep -qE '(^|[^a-z])john|hashcat|hashid|--wordlist' && L="$L crack"
  printf '%s' "$c" | grep -qE '/dev/tcp/|bash -i|(^|[^a-z])nc .* -e|pwncat|msfconsole|meterpreter|reverse.?shell|/bin/sh -i|setsid' && L="$L shell"
  printf '%s' "$c" | grep -qE 'chisel|ligolo|(^|[^a-z])socat|proxychains|port.?forward|(^|[^a-z])-L [0-9]' && L="$L pivot"
  printf '%s' "$c" | grep -qE '(^|[^a-z])gdb|objdump|readelf|(^|[^a-z])strings |ghidra|radare|(^|[^a-z])r2 |pwndbg' && L="$L reversing"
  # ── technique hint (observable from the command text only) ──
  printf '%s' "$c" | grep -qE 'login|/auth|signin|passwd|password=|token=|cookie=|authorization|(^|[^a-z])ntlm' && L="$L auth"
  printf '%s' "$c" | grep -qE 'sqlmap|union[ +]select|1=1|information_schema|xp_cmdshell|sleep\(|benchmark\(' && L="$L injection"
  printf '%s' "$c" | grep -qE '\.\./|\.\.%2f|%2e%2e|/etc/passwd|/proc/self|file://' && L="$L traversal"
  printf '%s' "$c" | grep -qE 'gopher://|169\.254|/metadata|(^|[^a-z])ssrf' && L="$L ssrf"
  printf '%s' "$c" | grep -qE '\{\{|\$\{|<%=|freemarker|jinja|twig|velocity' && L="$L template"
  printf '%s' "$c" | grep -qE '<!entity|<!doctype|(^|[^a-z])xxe' && L="$L xxe"
  printf '%s' "$c" | grep -qE 'pickle|yaml\.load|unserialize|objectinputstream|marshal|__reduce__' && L="$L deserialize"
  printf '%s' "$c" | grep -qE 'multipart/form-data|filename=|(^| )-f [^ -]' && L="$L upload"
  printf '%s' "$c" | grep -qE 'openssl|(^|[^a-z])jwt|(^| )gpg |\.pem( |$)|aes-|(^| )rsa ' && L="$L crypto"
  # ── target qualifier: cloud subcommand (service), else url/ip/host/port ──
  if printf '%s' " $L " | grep -q ' cloud '; then
    tgt="$(printf '%s' "$c" | sed "s/[\"']/ /g" | awk '{ for(i=1;i<=NF;i++) if($i ~ /^(aws|gcloud|az|kubectl|oc|doctl)$/){ skip=0; for(j=i+1;j<=NF;j++){ if($j ~ /^--?(region|profile|output|endpoint|endpoint-url|context|namespace|cluster|n|o|p|r)$/){skip=1;continue} if(skip){skip=0;continue} if($j ~ /^-/){continue} if($j ~ /^[a-z][a-z0-9-]*$/){print $j; exit} } } }')"
  fi
  if [ -z "$tgt" ]; then
    tgt="$(printf '%s' "$c" | grep -oE 'https?://[^/ "'"'"']+' | head -1 | sed -E 's#https?://##')"
    [ -z "$tgt" ] && tgt="$(printf '%s' "$c" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?' | head -1)"
    [ -z "$tgt" ] && tgt="$(printf '%s' "$c" | grep -oE '[a-z0-9][a-z0-9.-]*\.(htb|local|lan|internal)' | head -1)"
    if [ -z "$tgt" ]; then
      local p; p="$(printf '%s' "$c" | grep -oE '(-p|--port|port)[ =]+[0-9]{1,5}' | grep -oE '[0-9]+' | head -1)"
      [ -n "$p" ] && tgt="p$p"
    fi
  fi
  # dedup (keep order); fallback to the tool basename so an unmatched action is never a bare "other"
  L="$(printf '%s\n' $L | awk 'NF && !seen[$0]++' | paste -sd' ' -)"
  if [ -z "$L" ]; then
    local tool; tool="$(printf '%s' "$c" | sed -E 's/^[[:space:]]*(sudo([[:space:]]+-[a-z]+)*[[:space:]]+)?//; s/^([a-z_][a-z0-9_]*=[^ ]*[[:space:]]+)+//' | awk '{print $1}')"; tool="${tool##*/}"
    L="${tool:-other}"
  fi
  [ -n "$tgt" ] && L="$L @$tgt"
  printf '%s\n' "$L"
}

# rc2_guard_msg <reason> <hypo> <exp> <ceil> <rep> — structured message to the agent (point 7: echoes
# the action it was about to take + the ledger snapshot + the concrete alternatives).
rc2_guard_msg() {
  local bc; bc="$(printf '%s' "$input" | jq -r '.tool_input.command // (.tool_name) // "?"' 2>/dev/null | tr -s ' \t\n' ' ' | cut -c1-160)"
  {
    echo "redcat2 guard [$GUARD_MODE]: $1."
    echo "  ledger: current=$2  experiments=$3/$4  repeat_on_$2=$5"
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
  # frozen = solver's own freeze (ledger) OR an arbiter freeze (accounting, solver cannot clear) — guard_lib
  frozen=false; rc2_is_frozen "$cwd" "$cur" && frozen=true
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
        rc2_json_update "$ACCT" '.consumed_overrides=((.consumed_overrides // [])+[$n]) | .global.overrides_used=((.global.overrides_used // 0)+1)' --arg n "$ov_nonce"
        echo "redcat2 guard: OVERRIDE consumed for $cur (reason: ${ov_reason:-none}) — allowed ONCE. [$reason] Repeated overrides on $cur will require arbiter sign-off." >&2
      else
        rc2_guard_msg "$reason" "$cur" "$exp" "$ceil" "$new_rep"
        if [ "$GUARD_MODE" = "block" ]; then
          rc2_json_update "$ACCT" '.freeze_candidate={hypothesis:$h, reason:"repeat/stall/frozen", at:(now|todate)}' --arg h "$cur"
          return 2
        fi
      fi
    elif [ "$exp" -ge "$warn" ] 2>/dev/null; then
      echo "redcat2 guard (warn): $exp experiments (warn@$warn, ceiling $ceil). If worldmodel.md isn't gaining facts, zoom out and re-rank hypotheses." >&2
    fi
  fi

  # multi-label surface: _hook_surface emits a space-separated set, and EVERY label is incremented (so
  # .surfaces counts per-dimension effort; the totals intentionally exceed the action count).
  local surfs; surfs="$(_hook_surface "$(printf '%s' "$input" | jq -r '.tool_input.command // (.tool_name) // ""' 2>/dev/null)")"
  rc2_json_update "$ACCT" \
     '.global.experiments=((.global.experiments // 0)+1)
      | .per_hypothesis[$h]=((.per_hypothesis[$h] // {spent:0,repeat_count:0})
          | .spent=((.spent // 0)+1)
          | .repeat_count=(if (.last_action_fp // "")==$fp then ((.repeat_count // 0)+1) else 1 end)
          | .last_action_fp=$fp | .last_utc=(now|todate))
      | reduce (($surfs // "") | split(" ")[] | select(length>0)) as $s (.; .surfaces[$s]=((.surfaces[$s] // 0)+1))
      | .updated_utc=(now|todate)' \
     --arg h "$cur" --arg fp "$fp" --arg surfs "$surfs"
  return 0
}

# rc2_auditor_push — PUSH channel for the epistemic auditor (scripts/auditor.sh). When auditor.md
# carries a finding (AUDITOR_TICK) the solver has not yet read, nudge it to read it on the very next
# tool call; escalate from warn (stderr, return 0 — same convention as the guard warn) to a hard block
# (return 2) after AUDITOR_NUDGE_ESCALATE un-acked calls. A Read of auditor.md ACKs the current tick and
# clears the push (self-healing: the auditor re-bumps the tick next cycle if the finding still stands).
# This is the only difference from the supervisor channel, which is pull-only (solver reads it each loop).
rc2_auditor_push() {
  local aud="$cwd/auditor.md" nf="$logdir/.auditor_nudge" esc="${AUDITOR_NUDGE_ESCALATE:-3}"
  [ -f "$aud" ] || return 0
  local atick; atick="$(grep -oE '^AUDITOR_TICK: [0-9]+' "$aud" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  [ -n "$atick" ] || return 0
  local tn fp2
  tn="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
  fp2="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  # the solver reading auditor.md right now = acknowledgement -> record the tick, stop pushing it
  if [ "$tn" = "Read" ] && printf '%s' "$fp2" | grep -q 'auditor\.md$'; then
    echo "$atick ACK" > "$nf" 2>/dev/null; return 0
  fi
  local seen cnt; read -r seen cnt < "$nf" 2>/dev/null; seen="${seen:-0}"; cnt="${cnt:-0}"
  [ "$seen" = "$atick" ] && [ "$cnt" = "ACK" ] && return 0   # already acked this tick
  if [ "$seen" != "$atick" ]; then cnt=1; else cnt=$((cnt+1)); fi
  echo "$atick $cnt" > "$nf" 2>/dev/null
  if [ "$cnt" -ge "$esc" ] 2>/dev/null; then
    echo "redcat2 auditor [BLOCK]: an independent evidence-quality audit (auditor.md, AUDITOR_TICK $atick) flags a negative you are leaning on as resting on INCONCLUSIVE evidence — a test that never reached the mechanism (FAULT/timeout/transport/tooling), scored as if the mechanism answered. You have taken $cnt actions without reading it. STOP: Read auditor.md in full, then re-open the flagged vector with a materially-different attempt, or PARK it as untestable (naming the missing capability) — do NOT leave it recorded as a flat refutation. Reading auditor.md clears this block." >&2
    return 2
  fi
  echo "redcat2 auditor (push $cnt/$esc): new finding in auditor.md (AUDITOR_TICK $atick) — a vector you are treating as dead may rest on INCONCLUSIVE evidence (a test that never ran). Read auditor.md before scoring it refuted; follow its DO NEXT (a materially-different attempt at the same vector, or PARK as untestable). doctrine 10 → conclusiveness, not effort, governs a freeze." >&2
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

  # PUSH: epistemic auditor finding (auditor.md) — warn, then hard-block if ignored. Fail-open.
  rc2_auditor_push; apc=$?; [ "${apc:-0}" -eq 2 ] && exit 2

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

# P1 progress signal (G1: "evidence movement", not just worldmodel) — composite of worldmodel.md
# content + confirmed_path length + loot file count. Any of them moving = progress -> stamp it, which
# resets the stall clock the watcher/guard read. Cheap; fail-open.
if [ -s "$ACCT" ]; then
  wm="$(md5sum "$cwd/worldmodel.md" 2>/dev/null | cut -c1-16)"
  cp="$(jq -r '.confirmed_path | length' "$cwd/ledger.json" 2>/dev/null)"; cp="${cp:-0}"
  loot="$(find "$cwd/loot" -type f 2>/dev/null | wc -l | tr -d ' ')"
  sig="${wm:-0}:${cp}:${loot:-0}"
  pfp="$(jq -r '.progress.last_progress_fp // empty' "$ACCT" 2>/dev/null)"
  if [ "$sig" != "$pfp" ]; then
    rc2_json_update "$ACCT" '.progress.last_progress_fp=$f | .progress.last_progress_utc=(now|todate) | .progress.last_progress_experiment=(.global.experiments // 0) | .progress.stale_ticks=0' --arg f "$sig"
  fi
fi
exit 0
