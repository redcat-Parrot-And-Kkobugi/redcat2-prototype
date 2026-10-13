#!/usr/bin/env bash
# =============================================================================
#  run.sh — run-dir scaffold + (Stage C) prompt assembly and the resilient run
#  loop. Needs $RC2_ROOT and the resolve_target globals. Sourced via bootstrap.sh.
# =============================================================================

# Scaffold the run dir + seed the three living-memory files. Sets global RUNDIR, echoes it.
rc2_scaffold() {
  # slug = the real machine name, case preserved (spaces -> _, unsafe chars dropped).
  local slug; slug="$(printf '%s' "${MACHINE_NAME:-$TARGET_IP}" | tr ' ' '_' | tr -cd 'A-Za-z0-9_.-')"
  RUNDIR="$RC2_ROOT/runs/$slug"
  # FRESH=1 -> archive any existing run so this starts clean (old memory is kept, not deleted).
  if [ "${FRESH:-}" = "1" ] && [ -d "$RUNDIR" ]; then
    local bak="$RUNDIR.bak.$(date +%s)"; mv "$RUNDIR" "$bak"
    echo "[fresh] archived previous run -> $(basename "$bak")" >&2
  fi
  mkdir -p "$RUNDIR"/{tmp,recon,enum,loot/{hashes,keys,tickets,files},exploit,tools,bin,research,reversing,notes,logs/raw,tmp,.claude}
  # agents available to `claude -p` (cwd = run dir): symlink the team in.
  [ -e "$RUNDIR/.claude/agents" ] || ln -s "$RC2_ROOT/.claude/agents" "$RUNDIR/.claude/agents" 2>/dev/null || true
  # repo tools reachable from the run dir without cd (doctrine prefers absolute paths; this is the convenience fallback)
  [ -e "$RUNDIR/scripts" ] || ln -s "$RC2_ROOT/scripts" "$RUNDIR/scripts" 2>/dev/null || true
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
## Privilege map
- target: unknown principals/services — map who runs ABOVE you and what input of yours reaches them (elevation candidates)
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
$(rc2_utc) START — target ${MACHINE_NAME:-$TARGET_IP} ($TARGET_IP). First pass: ORIENT says information is the bottleneck; open with full-surface enumeration.
MD
  : > "$RUNDIR/flags.txt" 2>/dev/null || true
  # guard live-mode channel secret: oversee/operator tag logs/guard.mode with this; the solver is
  # forbidden to read it (doctrine). Seed once; stable across relaunches so a resume keeps the channel.
  if [ ! -s "$RUNDIR/logs/.guard_secret" ]; then
    ( umask 077; printf '%s' "$( { head -c16 /dev/urandom 2>/dev/null; echo "$$ $(date +%s%N 2>/dev/null) $RANDOM"; } | md5sum 2>/dev/null | cut -c1-32)" > "$RUNDIR/logs/.guard_secret" ) 2>/dev/null || true
    chmod 600 "$RUNDIR/logs/.guard_secret" 2>/dev/null || true
  fi
  # machine-readable state (P0). Two files on purpose (see doctrine 40):
  #   ledger.json          = the agent's INTENT (model-owned; mirrors hypotheses.md)
  #   logs/accounting.json = the hook's COUNTERS (plumbing-owned; agent never writes it)
  # Seed only if absent so a relaunch/resume preserves them (the disk is the memory).
  [ -s "$RUNDIR/ledger.json" ] || cat > "$RUNDIR/ledger.json" <<JSON
{
  "schema": 1,
  "updated_utc": "$(rc2_utc)",
  "current_hypothesis": "H1",
  "hypotheses": {
    "H1": { "claim": "The exposed surface is unknown and must be mapped before any attack", "target": "full surface", "status": "open", "budget_max": ${RC2_BUDGET_DEFAULT:-8}, "freeze": { "frozen": false, "confidence": null, "reason": "", "by": "self", "resumable": true, "at": "" } }
  },
  "confirmed_path": [],
  "negatives": [],
  "override": null
}
JSON
  [ -s "$RUNDIR/logs/accounting.json" ] || cat > "$RUNDIR/logs/accounting.json" <<JSON
{
  "schema": 1,
  "updated_utc": "$(rc2_utc)",
  "global": { "experiments": 0, "ceiling": ${RC2_CEIL:-800}, "warn_at": ${RC2_WARN:-450}, "overrides_used": 0 },
  "per_hypothesis": {},
  "progress": { "last_progress_utc": null, "last_progress_fp": null, "last_progress_experiment": 0 },
  "supervisor": { "consecutive_rabbit_hole": 0, "last_verdict": null, "last_fp": null, "gated": false },
  "consumed_overrides": [],
  "freeze_candidate": null,
  "arbiter_freezes": {},
  "judge": { "last_experiment": {} },
  "surfaces": {}
}
JSON
  echo "$RUNDIR"
}

# ── prompt assembly ──────────────────────────────────────────────────────────
# System prompt = the doctrine (brain), concatenated in numeric order (00..60).
rc2_build_sysprompt() { cat "$RC2_ROOT"/doctrine/*.md 2>/dev/null; }

# Launch prompt. Uses: machine_name target_ip os_hint difficulty RC2_TMUX tmux_base SECLISTS NOTES.
rc2_build_prompt() {
  printf '%s' "You are redcat2, hunting the authorized lab machine ${machine_name:-$target_ip} at \
target_ip=$target_ip (os=${os_hint:-unknown}, difficulty=${difficulty:-unknown}). Your cwd is this \
box's run dir; everything is relative to it. Your memory is worldmodel.md, hypotheses.md, journal.md \
— READ ALL THREE FIRST (they may already hold progress from a prior session; continue, do not restart), \
then run the Hunt Loop from your system prompt until user.txt AND root.txt are captured and VERIFIED. \
Keep the three living files current every loop; keep raw output under recon/ enum/ loot/ exploit/ \
research/. Delegate: web research & dorking -> researcher; walls of output -> recon-analyst; exploit \
code -> exploit-dev; binaries to reverse -> reverser (export-first); verifying a win or a \
risky/one-shot action -> verifier (use the Task tool). \
Research the live internet whenever an action depends on something you don't know cold, and read any \
exploit before running it. Install or build any tool you need on the fly (sudo -A for root; never put \
a password in a command). Run long/interactive commands in tmux session '$RC2_TMUX' (extra sessions: \
${tmux_base}_<slug>). Wordlists at \$SECLISTS=$SECLISTS. The moment you read a real flag, append \
user=<hex> or root=<hex> to flags.txt AND emit <FLAG><hex></FLAG> — a watcher auto-submits it. Act \
ONLY against $target_ip. Scale effort to the box: on easy/medium targets the shortest path is usually a \
single known technique — find it fast and don't over-engineer; on hard/insane expect to research and build \
a chain. If every live hypothesis is refuted and no new surface remains, write a precise blocker note in \
journal.md and stop — do not grind or fabricate progress. $NOTES"
}

# ── resilient run loop ───────────────────────────────────────────────────────
# A crash or context overflow (non-zero exit) auto-relaunches a FRESH headless agent, which resumes
# from the three living files (disk is the memory). A CLEAN stop (exit 0 = flags or a written blocker)
# is NOT second-guessed. NO_RESTART=1 runs once. Uses: PROMPT MODEL SYSPROMPT CONV LOG MAX_RESTARTS
# NO_RESTART RUNDIR TARGET RC2_ROOT. Sets global RUN_PID (so cleanup can kill the agent).

# rc2_relaunch_target_line <rundir> — on a relaunch, print the current target IP (banner-style),
# best-effort refreshing it from the HTB API in case the box was respawned to a NEW ip (id-matched,
# so an unrelated active machine is never picked up). Never fatal: with no API/token it just prints
# the known target_ip. target.env is rewritten only when the ip actually changed, so a running hunt
# — which already sourced run.sh and only re-reads target.env in its watchers — is not disrupted.
rc2_relaunch_target_line() {
  local rundir="$1" ip="${target_ip:-?}" act live
  if [ "${RC2_HTB:-0}" = "1" ] && [ -n "${machine_id:-}" ]; then
    act="$(htb_active 2>/dev/null)"
    if [ "$(printf '%s' "$act" | jq -r '.info.id // empty' 2>/dev/null)" = "$machine_id" ]; then
      live="$(printf '%s' "$act" | jq -r '.info.ip // empty' 2>/dev/null)"
      if [ -n "$live" ] && [ "$live" != "null" ] && [ "$live" != "$ip" ]; then
        [ -f "$rundir/target.env" ] && sed -i "s/^target_ip=.*/target_ip=\"$live\"/" "$rundir/target.env" 2>/dev/null || true
        export target_ip="$live"
        printf '\033[33m[hunt] target IP changed: %s -> %s (box respawned)\033[0m\n' "$ip" "$live" | tee -a "$LOG"
        ip="$live"
      fi
    fi
  fi
  printf '[hunt] target: %s (%s)\n' "$ip" "${machine_name:-?}" | tee -a "$LOG"
}

# A cyber-safeguard refusal is CONTENT-based: a fresh session with the same task re-trips it, so we
# relaunch only a few times (CYBER_MAX_RETRIES, default 10) then stop with a hint — the real fix is a
# less-restricted model (CYBER_FALLBACK_MODEL) or the Cyber Verification Program, not more relaunches.
_rc2_log_has_cyber() { tail -n 60 "${1:-/dev/null}" 2>/dev/null | grep -qiE 'safeguards flagged|\[cyber\]|Cyber Verification|cyber safeguard'; }

# _rc2_attempt_guard <conv> <cyber0> <pid> <attempt> — backgrounded liveness watchdog for ONE claude -p
# attempt. Fixes the "it just paused" failure: the hunt terminal is silent during an attempt (the agent
# stream is redirected to the log, not here), so a long, spinning, or wedged attempt is indistinguishable
# from a hang — and nothing bounds a single attempt, so `wait` can block for many minutes (or forever).
# This runs in its OWN subshell (set +e: never abort the hunt), and on each tick:
#   * emits a heartbeat to the hunt terminal so a live attempt never looks paused;
#   * if the attempt has tripped the cyber safeguard >= RC2_CYBER_SPIN times, kills it — a fresh session
#     re-trips the same CONTENT flag, so grinding the rest of the attempt is pure waste (the kill message
#     says "cyber safeguard" so the loop counts it toward CYBER_MAX_RETRIES and stops cleanly at the cap);
#   * if the attempt has emitted nothing for RC2_HANG_KILL s, kills it as wedged (-> crash relaunch).
# Thresholds are env-tunable; set any to 0 to disable that check. cyber0 is the cyber-flag count captured
# pre-launch so the count stays per-attempt (CONV is appended across the whole run).
_rc2_attempt_guard() {
  set +e                                   # own subshell (backgrounded) — never let a check abort the hunt
  local conv="$1" cyber0="$2" pid="$3" attempt="$4"
  local beat="${RC2_HEARTBEAT:-60}" spin="${RC2_CYBER_SPIN:-10}" hang="${RC2_HANG_KILL:-600}" tick="${RC2_GUARD_TICK:-15}"
  local start now size last_size last_change last_beat cyc el
  start=$(date +%s); last_change=$start; last_beat=$start
  last_size=$(wc -c < "$conv" 2>/dev/null || true); last_size=${last_size:-0}
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$tick"; kill -0 "$pid" 2>/dev/null || break
    now=$(date +%s); el=$((now-start))
    size=$(wc -c < "$conv" 2>/dev/null || true); size=${size:-0}
    [ "$size" != "$last_size" ] && { last_size=$size; last_change=$now; }
    cyc=$(grep -c '\[cyber\]' "$conv" 2>/dev/null || true); cyc=$(( ${cyc:-0} - cyber0 )); [ "$cyc" -lt 0 ] && cyc=0
    if [ "$spin" -gt 0 ] && [ "$cyc" -ge "$spin" ]; then
      printf '\033[31m[hunt] attempt %d hit the cyber safeguard %dx this session — killing it (a fresh session re-trips the same content flag)\033[0m\n' "$attempt" "$cyc" | tee -a "$LOG"
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; return 0
    fi
    if [ "$hang" -gt 0 ] && [ "$((now-last_change))" -ge "$hang" ]; then
      printf '\033[31m[hunt] attempt %d emitted nothing for %ds — wedged, killing it (will relaunch)\033[0m\n' "$attempt" "$((now-last_change))" | tee -a "$LOG"
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; return 0
    fi
    if [ "$beat" -gt 0 ] && [ "$((now-last_beat))" -ge "$beat" ]; then
      printf '\033[2m[hunt] attempt %d live — %dm%02ds elapsed, %d cyber-flag(s) this session\033[0m\n' "$attempt" "$((el/60))" "$((el%60))" "$cyc" | tee -a "$LOG"
      last_beat=$now
    fi
  done
}

rc2_run_loop() {
  local attempt=0 rc cyber_tries=0 surrender_reopens=0
  local PRETTY=(cat); [ -f "$RC2_ROOT/scripts/conv_fmt.py" ] && PRETTY=(python3 "$RC2_ROOT/scripts/conv_fmt.py")
  while :; do
    attempt=$((attempt+1))
    if [ "$attempt" -gt 1 ]; then
      printf '\033[33m[hunt] relaunch %d/%d — resuming from disk memory\033[0m\n' "$attempt" "$MAX_RESTARTS" | tee -a "$LOG"
      rc2_relaunch_target_line "$RUNDIR"
    fi
    local _cyber0; _cyber0=$(grep -c '\[cyber\]' "$CONV" 2>/dev/null || true); _cyber0=${_cyber0:-0}
    claude -p "$PROMPT" \
      --output-format stream-json \
      --model "$MODEL" \
      --append-system-prompt "$SYSPROMPT" \
      --dangerously-skip-permissions \
      --verbose \
      > >(tee -a "$CONV" | "${PRETTY[@]}" >> "$LOG") 2>&1 &   # conv -> CONV (watch.sh renders it) + LOG; NOT the hunt terminal
    RUN_PID=$!          # global on purpose: cleanup() kills it
    local _guard_pid=""
    _rc2_attempt_guard "$CONV" "$_cyber0" "$RUN_PID" "$attempt" & _guard_pid=$!   # heartbeat + spin/wedge kill
    rc=0; wait "$RUN_PID" || rc=$?   # errexit-safe: a non-zero agent exit must NOT abort the loop
    if [ -n "$_guard_pid" ]; then kill "$_guard_pid" 2>/dev/null || true; wait "$_guard_pid" 2>/dev/null || true; fi
    if rc2_solved "$RUNDIR"; then echo "[hunt] both flags captured + accepted — done." | tee -a "$LOG"; break; fi
    if [ "${NO_RESTART:-0}" = "1" ]; then echo "[hunt] NO_RESTART=1 — single run complete (rc=$rc)." | tee -a "$LOG"; break; fi
    # cyber-safeguard refusal: relaunch a fresh session, but cap it (content flags re-trip) — checked
    # before the clean-exit branch because a flagged run can look like rc=0.
    if _rc2_log_has_cyber "$LOG"; then
      cyber_tries=$((cyber_tries+1))
      if [ -n "${CYBER_FALLBACK_MODEL:-}" ] && [ "$MODEL" != "${CYBER_FALLBACK_MODEL}" ]; then
        echo "[hunt] cyber safeguard — switching to CYBER_FALLBACK_MODEL=$CYBER_FALLBACK_MODEL for the next session" | tee -a "$LOG"; MODEL="$CYBER_FALLBACK_MODEL"
      fi
      if [ "$cyber_tries" -gt "${CYBER_MAX_RETRIES:-10}" ]; then
        echo "[hunt] cyber safeguard hit ${cyber_tries}x (cap ${CYBER_MAX_RETRIES:-10}) — stopping. A fresh session won't clear a content-based flag; set CYBER_FALLBACK_MODEL=<less-restricted model> or apply to the Cyber Verification Program." | tee -a "$LOG"; break
      fi
      printf '\033[33m[hunt] agent hit a cyber safeguard — relaunching a fresh session (%d/%s)\033[0m\n' "$cyber_tries" "${CYBER_MAX_RETRIES:-10}" | tee -a "$LOG"; sleep 3; continue
    fi
    if [ "$rc" -eq 0 ]; then
      # C (surrender gate): before respecting a clean-exit blocker, let an independent reviewer
      # re-audit the pruned/weak negatives. A concrete REOPEN relaunches with that directive; bounded.
      if _rc2_surrender_on && [ "$surrender_reopens" -lt "${RC2_SURRENDER_MAX:-2}" ]; then
        local sv verdict comp prim rsn
        printf '\033[36m[surrender-gate] agent declared a blocker — independent re-audit (%s) ...\033[0m\n' "${RC2_SURRENDER_MODEL:-claude-opus-4-8}" | tee -a "$LOG"
        sv="$(rc2_surrender_gate "$RUNDIR")"
        verdict="$(printf '%s' "$sv" | jq -r '.verdict // "ACCEPT"' 2>/dev/null)"
        if [ "$verdict" = "REOPEN" ]; then
          comp="$(printf '%s' "$sv" | jq -r '.component // "?"' 2>/dev/null)"
          prim="$(printf '%s' "$sv" | jq -r '.primitive // "?"' 2>/dev/null)"
          rsn="$(printf '%s' "$sv" | jq -r '.reason // ""' 2>/dev/null)"
          if [ -n "$comp" ] && [ "$comp" != "?" ]; then
            rc2_surrender_directive "$RUNDIR" "$comp" "$prim" "$rsn"
            surrender_reopens=$((surrender_reopens+1))
            printf '\033[31m[surrender-gate] REOPEN %d/%s: %s via %s — relaunching\033[0m\n' "$surrender_reopens" "${RC2_SURRENDER_MAX:-2}" "$comp" "$prim" | tee -a "$LOG"; sleep 3; continue
          fi
        fi
        echo "[surrender-gate] ACCEPT — surrender is real (no under-tested higher-privilege re-open found)." | tee -a "$LOG"
      fi
      echo "[hunt] agent stopped cleanly without both flags (blocker/stuck). Respecting it — not relaunching. Re-run ./hunt $TARGET to continue." | tee -a "$LOG"; break
    fi
    if [ "$attempt" -ge "$MAX_RESTARTS" ]; then echo "[hunt] hit MAX_RESTARTS=$MAX_RESTARTS (last rc=$rc) — stopping." | tee -a "$LOG"; break; fi
    printf '\033[31m[hunt] agent exited rc=%s (crash/overflow) — will relaunch\033[0m\n' "$rc" | tee -a "$LOG"; sleep 3
  done
}

# ── live confirmed-path (P0) ─────────────────────────────────────────────────
# rc2_writeup_confirmed <rundir> — maintain a "Confirmed path" block at the TOP of writeup.md,
# regenerated each status tick from ledger.json (.confirmed_path), falling back to the confirmed
# blocks in hypotheses.md. Idempotent (owns its RC2:CONFIRMED-PATH markers) and placed ABOVE
# report.sh's WRITEUP:START, which preserves everything above it — so the on-exit narrative keeps it.
# Fail-open: any error leaves writeup.md as-is and never disrupts the run.
rc2_writeup_confirmed() {
  local rundir="$1" wu="$1/writeup.md" led="$1/ledger.json" nf list
  local B="<!-- RC2:CONFIRMED-PATH:START (live, auto — edit below the END marker) -->"
  local E="<!-- RC2:CONFIRMED-PATH:END -->"
  list=""
  [ -s "$led" ] && list="$(jq -r '.confirmed_path[]? | "- **\(.h)** — \(.summary)"' "$led" 2>/dev/null)"
  [ -n "$list" ] || list="$(awk '/^### H/ && /confirmed/{l=$0; sub(/^### /,"- ",l); print l}' "$rundir/hypotheses.md" 2>/dev/null)"
  [ -n "$list" ] || list="- (none confirmed yet)"
  nf="$(mktemp)" || return 0
  {
    echo "$B"
    echo "## ✅ Confirmed path (live)"
    echo "_auto from ledger.json each status tick — VERIFY-confirmed links only_"
    echo
    printf '%s\n' "$list"
    echo
    echo "$E"
  } > "$nf"
  touch "$wu" 2>/dev/null || { rm -f "$nf"; return 0; }
  if grep -qF "RC2:CONFIRMED-PATH:START" "$wu" 2>/dev/null; then
    awk -v f="$nf" 'index($0,"RC2:CONFIRMED-PATH:START"){while((getline l<f)>0)print l; close(f); skip=1} index($0,"RC2:CONFIRMED-PATH:END"){skip=0;next} !skip{print}' "$wu" > "$wu.tmp" 2>/dev/null && mv "$wu.tmp" "$wu" 2>/dev/null
  else
    { cat "$nf"; echo; cat "$wu" 2>/dev/null; } > "$wu.tmp" 2>/dev/null && mv "$wu.tmp" "$wu" 2>/dev/null
  fi
  rm -f "$nf"
}

# ── periodic status snapshot ─────────────────────────────────────────────────
# rc2_write_status <rundir> — one machine-generated snapshot of the CURRENT situation into
# <rundir>/status.md (operator view + resume aid). Reads meta.env for start/elapsed. Safe anytime.
rc2_write_status() {
  local rundir="$1" L="$1/logs" tb now start elapsed
  [ -d "$rundir" ] || return 0
  now="$(rc2_utc)"
  start="$( [ -f "$L/meta.env" ] && . "$L/meta.env" 2>/dev/null; echo "${start_epoch:-$(date +%s)}")"
  elapsed=$(( ($(date +%s) - start) / 60 ))
  # one subshell source of target.env (no leak into the status-writer loop), fields tab-split out
  local mn ti os df _t
  _t="$( rc2_load_target "$rundir" 2>/dev/null; printf '%s\t%s\t%s\t%s\t%s' "${machine_name:-?}" "${target_ip:-?}" "${os_hint:-?}" "${difficulty:-?}" "${tmux_base:-rc2}" )"
  IFS=$'\t' read -r mn ti os df tb <<<"$_t"
  {
    echo "# status — ${mn}"
    echo "_updated ${now} · elapsed ${elapsed}m · target ${ti} · os ${os} · diff ${df}_"
    echo "> auto-written periodically — do NOT hand-edit (your record lives in journal.md)."
    echo
    echo "## flags"; sed 's/^/- /' "$rundir/flags.txt" 2>/dev/null
    [ -s "$L/flag_submit.log" ] && { echo; echo "### submissions (recent)"; tail -5 "$L/flag_submit.log" | sed 's/^/- /'; }
    echo
    echo "## phase"
    [ -s "$L/phases.log" ] && tail -1 "$L/phases.log" | sed 's/^/- /' || echo "- (none logged)"
    echo
    echo "## hypotheses"
    echo "- confirmed: $(grep -ciE 'status:[[:space:]]*confirmed' "$rundir/hypotheses.md" 2>/dev/null)   frozen/refuted: $(grep -ciE 'status:[[:space:]]*(frozen|refuted)' "$rundir/hypotheses.md" 2>/dev/null)"
    grep -nE '^### H' "$rundir/hypotheses.md" 2>/dev/null | sed 's/^[0-9]*:/  /' | head -12
    echo
    echo "## ledger (machine state)"
    echo "- guard: floor=${RC2_GUARD:-off} · live=$( [ -s "$L/guard.mode" ] && { sed -n 's/^mode=//p' "$L/guard.mode" 2>/dev/null | head -1; } || echo none ) · effective=$(rc2_guard_effective "$rundir" 2>/dev/null)"
    if [ -s "$rundir/ledger.json" ]; then
      jq -r '
        "- current: \(.current_hypothesis // "—")   confirmed_path: \(.confirmed_path | length)",
        (.hypotheses | to_entries[] |
          "  - \(.key): \(.value.status)  budget_max=\(.value.budget_max)" +
          (if (.value.freeze.frozen // false) then "  ❄️ frozen(\(.value.freeze.confidence // "?"))" else "" end))
      ' "$rundir/ledger.json" 2>/dev/null || echo "- (ledger.json present but unreadable)"
    else
      echo "- (no ledger.json yet)"
    fi
    if [ -s "$L/accounting.json" ]; then
      jq -r '"- experiments: \(.global.experiments)/\(.global.ceiling) (warn@\(.global.warn_at)) · overrides: \(.global.overrides_used) · stall: \((.global.experiments // 0) - (.progress.last_progress_experiment // 0)) since last fact"
             + (if .freeze_candidate then "  ⚠️ freeze-candidate: \(.freeze_candidate.hypothesis)" else "" end)' "$L/accounting.json" 2>/dev/null || true
      jq -r '.per_hypothesis | to_entries[]? | "  - \(.key): spent=\(.value.spent) repeat=\(.value.repeat_count)"' "$L/accounting.json" 2>/dev/null || true
      jq -r '(.surfaces // {}) | to_entries | sort_by(-.value) | if length>0 then "  - surfaces: " + ([.[] | "\(.key):\(.value)"] | join("  ")) else empty end' "$L/accounting.json" 2>/dev/null || true
    fi
    echo
    echo "## journal (recent)"; tail -15 "$rundir/journal.md" 2>/dev/null | sed 's/^/  /'
    echo
    echo "## recent tool calls (last 15)"
    rc2_tl_recent "$L/tools.jsonl" 15
    echo
    echo "## tmux sessions"
    tmux ls -F '#{session_name}  (#{session_windows}w)' 2>/dev/null | grep -E "^${tb}" | sed 's/^/- /' || echo "- (none)"
    echo
    echo "## artifacts"
    local dd
    for dd in recon enum loot exploit reversing research tools bin; do
      printf -- "- %-10s %s files\n" "$dd" "$(find "$rundir/$dd" -type f 2>/dev/null | wc -l | tr -d ' ')"
    done
  } > "$rundir/status.md.tmp" 2>/dev/null && mv "$rundir/status.md.tmp" "$rundir/status.md" 2>/dev/null
  rc2_writeup_confirmed "$rundir" 2>/dev/null || true   # P0: keep writeup.md's confirmed-path block live
}

# rc2_status_writer <rundir> — blocking loop: snapshot every STATUS_INTERVAL (default 600s) until
# logs/.stop. Background it from hunt:  rc2_status_writer "$R" &  (cleanup kills it + writes a final one)
rc2_status_writer() {
  local rundir="$1" interval="${STATUS_INTERVAL:-600}" tick=30 last=0
  rc2_write_status "$rundir"; last=$(date +%s)
  while [ ! -f "$rundir/logs/.stop" ]; do
    sleep "$tick"
    if [ $(( $(date +%s) - last )) -ge "$interval" ]; then rc2_write_status "$rundir"; last=$(date +%s); fi
  done
}

# _rc2_recent_self_reset <rundir> — best-effort: did THIS run issue a reset/reboot recently? Greps the
# recent tail of the tool log + journal for a reset/stop/terminate/reboot action, to tell an EXPECTED
# down (the agent reset the box) from an UNEXPECTED one (HTB auto-reset/respawn or crash).
_rc2_recent_self_reset() {
  { tail -c 40000 "$1/logs/tools.jsonl" 2>/dev/null; tail -40 "$1/journal.md" 2>/dev/null; } \
    | grep -qiE 'machine\.sh +(reset|stop)|htb[-_ ].*(reset|stop|terminate)|\breboot\b|\bshutdown\b'
}

# rc2_health_watcher <rundir> — background target-liveness signal. When the BOX reboots underneath the
# hunt (HTB auto-reset/respawn, a crash, or a reset the agent did NOT issue), the agent otherwise only
# sees its commands start failing and can misread a reboot as "my exploit broke" or "this path is dead".
# This probes the target every HEALTH_INTERVAL s (default 30) and rewrites <rundir>/target_health.md — a
# signal the agent reads (doctrine 40) — flipping UP/DOWN with timestamps; on a DOWN it says whether a
# reset was recently logged from inside the run (EXPECTED) or not (UNEXPECTED: wait + re-probe, the IP may
# change on respawn, treat pre-reboot flags as stale). Fail-open; stops on logs/.stop. Background from hunt.
rc2_health_watcher() {
  set +e                                   # own subshell (backgrounded) — probes fail normally; never abort
  local rundir="$1" iv="${HEALTH_INTERVAL:-30}" ports="${HEALTH_PORTS:-22 80 443}" hf="$1/target_health.md" ip p up t0 note state="" since=""
  while [ ! -f "$rundir/logs/.stop" ]; do
    ip=""; [ -f "$rundir/target.env" ] && { . "$rundir/target.env" 2>/dev/null || true; ip="${target_ip:-}"; }
    up=0
    if [ -n "$ip" ]; then
      for p in $ports; do timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$p" 2>/dev/null && { up=1; break; }; done
    fi
    t0="$(date -u +%FT%TZ)"
    if [ "$up" = 1 ]; then
      [ "$state" = up ] || { state=up; since="$t0"; }
      printf '# 🎯 target health — UP\n_updated %s · ip %s · reachable_\n\nTarget is UP (since %s). Normal operation.\n' "$t0" "$ip" "$since" > "$hf" 2>/dev/null
    else
      [ "$state" = down ] || { state=down; since="$t0"; }
      if _rc2_recent_self_reset "$rundir"; then
        note="A reset/reboot WAS logged from this run recently — this down is EXPECTED. Wait for the box to return (poll :22/:80), then re-walk your confirmed_path. On HTB a reset ROTATES the flags, so re-read user.txt/root.txt after recovery before trusting or submitting any flag."
      else
        note="⚠️ UNEXPECTED: no reset/reboot was logged from this run. The box most likely auto-reset, respawned, or CRASHED under you — this is NOT your exploit breaking and NOT a dead path. Do not conclude a hypothesis failed from connection errors alone: wait and re-probe (:22/:80). The IP may change on respawn. Any flag read BEFORE this down may now be STALE (a reset rotates them) — re-read user.txt/root.txt after recovery before submitting."
      fi
      printf '# 🎯 target health — DOWN ⛔\n_updated %s · ip %s · UNREACHABLE since %s_\n\n%s\n' "$t0" "${ip:-?}" "$since" "$note" > "$hf" 2>/dev/null
    fi
    sleep "$iv"
  done
}

# ── P1-d: sameness-judge watcher ─────────────────────────────────────────────
# An independent judge (sonnet) decides whether the current hypothesis is being DRILLED (same approach,
# no evidence movement = rabbit hole -> persistent arbiter freeze) or genuinely VARIED (keep going).
# Independent of the solver (its own `claude -p`, run OUTSIDE the repo so no repo-local hook fires), so
# the solver cannot bias it. Fail-open throughout.

# rc2_claude_oneshot <model> <sysfile|""> <timeout> <prompt> — run an out-of-band `claude -p` from an
# isolated cwd OUTSIDE the repo (so no repo-local hook / auto-PR Stop hook fires), permissionless, with
# an optional --append-system-prompt file, bounded by <timeout>. Echoes raw stdout; empty on error.
# Shared by the sameness judge and the surrender gate — one home for the repo-isolation safety.
rc2_claude_oneshot() {
  local model="$1" sysfile="$2" tmo="$3" prompt="$4" jcwd out sys=""
  [ -n "$sysfile" ] && [ -f "$sysfile" ] && sys="$(cat "$sysfile" 2>/dev/null)"
  jcwd="$(mktemp -d "${GUARD_JUDGE_TMP:-/tmp}/rc2oneshot.XXXXXX" 2>/dev/null)" || return 0
  out="$( cd "$jcwd" && timeout "$tmo" claude -p "$prompt" --model "$model" --dangerously-skip-permissions ${sys:+--append-system-prompt "$sys"} 2>/dev/null )"
  rm -rf "$jcwd" 2>/dev/null || true
  printf '%s' "$out"
}

# rc2_negatives <rundir> — the agent's recorded NEGATIVES ("X absent/refuted/mock/closed…"): the one
# material both the surrender gate (re-audit) and the contradiction check read. Prefers the STRUCTURED
# list in ledger.json (`.negatives[]` = {fact, confidence, tested}) and always also folds in free-text
# matches from worldmodel/hypotheses, so it works before (or if) the agent mirrors them. Single
# definition of "what counts as a negative".
rc2_negatives() {
  local rundir="$1" led="$1/ledger.json"   # $1 (not $rundir) — same-statement local won't see $rundir yet
  jq -r '.negatives[]? | "- \(.fact)  [conf:\(.confidence // "?") · tested:\(.tested // "?")]"' "$led" 2>/dev/null
  grep -hiE 'closed|refuted|mock|absent|not present|no .*(sock|mount|priv)|dropped|denied|impossible|conf:[[:space:]]*(med|high)' \
    "$rundir/worldmodel.md" "$rundir/hypotheses.md" 2>/dev/null | cut -c1-200 | head -30
}

# rc2_run_sameness_judge <rundir> <hypo> — echoes the judge's one-line verdict JSON (or nothing).
rc2_run_sameness_judge() {
  local rundir="$1" h="$2" led="$1/ledger.json" J="$1/logs/tools.jsonl"   # $1 not $rundir (same-local gotcha)
  local claim target recent wm model="${GUARD_JUDGE_MODEL:-sonnet}" prompt
  claim="$(jq -r --arg h "$h" '.hypotheses[$h].claim // "?"' "$led" 2>/dev/null)"
  target="$(jq -r --arg h "$h" '.hypotheses[$h].target // "?"' "$led" 2>/dev/null)"
  recent="$(grep '"event":"pre"' "$J" 2>/dev/null | tail -24 | jq -r '(.command // .tool // "?")' 2>/dev/null | cut -c1-200)"
  wm="$(tail -40 "$rundir/worldmodel.md" 2>/dev/null)"
  local negs; negs="$(rc2_negatives "$rundir")"
  # prompt built with printf %s so logged commands (which may contain $(), backticks) are NEVER expanded
  prompt="$(printf '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s' \
    "Hypothesis under scrutiny ($h): \"$claim\"  (target: $target)." \
    "Recent actions taken on this hypothesis (most recent last):" "$recent" \
    "Current worldmodel.md tail (VERIFIED facts only):" "$wm" \
    "Recorded NEGATIVES (facts the agent marked absent/refuted — a recent action that PRESUPPOSES one is self-contradiction):" "$negs" \
    "Decide SAME vs VARYING, and flag any self-contradiction. Respond with ONLY the JSON object:" \
    '{"verdict":"SAME"|"VARYING","distinct_approaches":<int>,"confidence":"low"|"med"|"high","contradiction":"<refuted fact presupposed, or empty>","reason":"<=160 chars"}')"
  rc2_claude_oneshot "$model" "$RC2_ROOT/JUDGE.md" "${GUARD_JUDGE_TIMEOUT:-120}" "$prompt" | grep -oE '\{[^{}]*"verdict"[^{}]*\}' | head -1
}

# rc2_guard_commit_freeze <rundir> <hypo> <confidence> <reason> — authoritative freeze in accounting
# (solver cannot clear it) + mirror into ledger (the model's view) + journal/guard.log note.
rc2_guard_commit_freeze() {
  local rundir="$1" h="$2" conf="$3" reason="$4" acct="$1/logs/accounting.json" led="$1/ledger.json"   # $1 not $rundir (same-local gotcha)
  local resumable=true; [ "$conf" = "high" ] && resumable=false
  rc2_json_update "$acct" '.arbiter_freezes[$h]={confidence:$c,reason:$r,resumable:$res,by:"arbiter",at:(now|todate)} | .freeze_candidate=null' \
     --arg h "$h" --arg c "$conf" --arg r "$reason" --argjson res "$resumable"
  rc2_json_update "$led" '.hypotheses[$h].status="frozen" | .hypotheses[$h].freeze={frozen:true,confidence:$c,reason:$r,by:"arbiter",resumable:$res,at:(now|todate)}' \
     --arg h "$h" --arg c "$conf" --arg r "$reason" --argjson res "$resumable"
  printf '%s ARBITER FROZE %s (conf=%s): %s — switch hypotheses (one-shot override in ledger.json if you truly disagree).\n' "$(rc2_utc)" "$h" "$conf" "$reason" >> "$rundir/journal.md" 2>/dev/null || true
  printf '%s froze %s conf=%s: %s\n' "$(rc2_utc)" "$h" "$conf" "$reason" >> "$rundir/logs/guard.log" 2>/dev/null || true
}

# rc2_guard_contradiction_signal <rundir> <hypo> <verdict-json> — if the judge flagged a self-
# contradiction (recent actions presuppose a fact recorded absent/refuted), signal the solver via a
# supervisor tick (debounced per-contradiction) to re-test that negative or open-enumerate. Else no-op.
rc2_guard_contradiction_signal() {
  local rundir="$1" cur="$2" v="$3" acct="$1/logs/accounting.json" contra cfp last_cfp
  contra="$(printf '%s' "$v" | jq -r '.contradiction // ""' 2>/dev/null | cut -c1-160)"
  [ -n "$contra" ] && [ "$contra" != "null" ] || return 0
  cfp="$(printf '%s' "$contra" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"; [ -n "$cfp" ] || return 0
  last_cfp="$(jq -r '.supervisor.last_contradiction_fp // ""' "$acct" 2>/dev/null)"
  [ "$cfp" != "$last_cfp" ] || return 0   # debounce: only a NEW contradiction
  rc2_write_supervisor "$rundir" "self-contradiction" "$(printf '%s\n\n%s\n%s\n%s\n%s\n%s' \
    "_the sameness judge caught you presupposing a fact you recorded as absent/refuted_" \
    "STATUS: minor-drift" \
    "FOCUS: contradiction-$cfp" \
    "READ: your recent actions presuppose '$contra' — but your own worldmodel records it absent/refuted." \
    "STOP: chasing that want." \
    "DO NEXT: either RE-TEST that negative properly if your evidence for it was shallow (doctrine 00/40 — a shallow negative is a hypothesis, not a fact), or DROP the want and OPEN-ENUMERATE the context (doctrine 10 — do not just check for the primitive you wanted; list what is actually present).")" >/dev/null
  rc2_json_update "$acct" '.supervisor.last_contradiction_fp=$f' --arg f "$cfp"
  printf '%s judge: CONTRADICTION on %s — presupposing refuted: %s\n' "$(rc2_utc)" "$cur" "$contra" >> "$rundir/logs/guard.log" 2>/dev/null || true
}

# rc2_guard_watcher <rundir> — periodic loop (GUARD_WATCH_INTERVAL, default 180s). Triggers the judge
# when the hook flagged a freeze_candidate OR the current hypothesis stalled >= RC2_STALL experiments
# with no new verified fact. Debounced per hypothesis so the judge is not called every tick.
rc2_guard_watcher() {
  # defaults centralized in env.sh (sourced by bootstrap before this runs); bare on purpose
  local rundir="$1" interval="${GUARD_WATCH_INTERVAL:-180}" stall="${RC2_STALL:-12}"
  local acct="$rundir/logs/accounting.json" led="$rundir/ledger.json"
  while [ ! -f "$rundir/logs/.stop" ]; do
    sleep "$interval"
    [ -s "$acct" ] && [ -s "$led" ] || continue
    local cur cand exp lastp lastj
    cur="$(jq -r '.current_hypothesis // empty' "$led" 2>/dev/null)"; [ -n "$cur" ] || continue
    rc2_is_frozen "$rundir" "$cur" && continue   # already frozen (solver or arbiter) — nothing to judge
    cand="$(jq -r '.freeze_candidate.hypothesis // empty' "$acct" 2>/dev/null)"
    exp="$(jq -r '.global.experiments // 0' "$acct" 2>/dev/null)"
    lastp="$(jq -r '.progress.last_progress_experiment // 0' "$acct" 2>/dev/null)"
    lastj="$(jq -r --arg h "$cur" '.judge.last_experiment[$h] // 0' "$acct" 2>/dev/null)"
    if { [ "$cand" = "$cur" ] || [ $((exp - lastp)) -ge "$stall" ] 2>/dev/null; } && [ $((exp - lastj)) -ge "$stall" ] 2>/dev/null; then
      local v verdict conf reason
      v="$(rc2_run_sameness_judge "$rundir" "$cur")"
      rc2_json_update "$acct" '.judge.last_experiment[$h]=$e' --arg h "$cur" --argjson e "$exp"
      [ -n "$v" ] || continue
      verdict="$(printf '%s' "$v" | jq -r '.verdict // empty' 2>/dev/null)"
      conf="$(printf '%s' "$v" | jq -r '.confidence // "med"' 2>/dev/null)"
      reason="$(printf '%s' "$v" | jq -r '.reason // "sameness judge"' 2>/dev/null | cut -c1-160)"
      rc2_guard_contradiction_signal "$rundir" "$cur" "$v"   # supervisor signal iff judge flagged a self-contradiction
      if [ "$verdict" = "SAME" ] && { [ "$conf" = "med" ] || [ "$conf" = "high" ]; }; then
        rc2_guard_commit_freeze "$rundir" "$cur" "$conf" "$reason"
      else
        rc2_json_update "$acct" '.freeze_candidate=null'
        printf '%s judge: %s on %s (conf=%s) — %s\n' "$(rc2_utc)" "${verdict:-none}" "$cur" "$conf" "$reason" >> "$rundir/logs/guard.log" 2>/dev/null || true
      fi
    fi
  done
}

# ── C: surrender gate ────────────────────────────────────────────────────────
# When the solver clean-exits as a blocker, an INDEPENDENT reviewer (opus) re-audits its privilege
# map + weak negatives + per-surface effort and either ACCEPTs the surrender or names a concrete
# REOPEN (component + elevation primitive). Mirror of the rabbit-hole guard: that stops over-drilling,
# this stops premature give-up. Runs OUTSIDE the repo (no repo-local hook). Fail-open.
_rc2_surrender_on() {
  [ "${NO_SURRENDER:-0}" = "1" ] && return 1
  rc2_guard_core_on || [ "${RC2_GUARD_WATCH:-0}" = "1" ]   # core (floor/gate) + judge-only watcher
}

# rc2_surrender_gate <rundir> — echoes the reviewer's verdict JSON (or nothing).
rc2_surrender_gate() {
  local rundir="$1" model="${RC2_SURRENDER_MODEL:-claude-opus-4-8}" prompt wm negs surf blocker
  wm="$(sed -n '/## Privilege map/,/## Open questions/p' "$rundir/worldmodel.md" 2>/dev/null | head -60)"
  [ -n "$wm" ] || wm="$(head -80 "$rundir/worldmodel.md" 2>/dev/null)"
  negs="$(rc2_negatives "$rundir")"
  surf="$(jq -r '.surfaces // {} | to_entries[]? | "  \(.key): \(.value)"' "$rundir/logs/accounting.json" 2>/dev/null | sort -t: -k2 -rn | head -20)"
  blocker="$(tail -40 "$rundir/journal.md" 2>/dev/null)"
  prompt="$(printf '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s' \
    "The solver declared a BLOCKER (no root). Re-audit before the surrender is accepted." \
    "PRIVILEGE MAP + facts:" "$wm" \
    "Recorded NEGATIVES (look for thinly-tested ones that could run above the agent):" "$negs" \
    "PER-SURFACE effort (calls; lopsided = under-explored surface):" "${surf:-  (none recorded)}" \
    "Blocker note (journal tail):" "$blocker")"
  rc2_claude_oneshot "$model" "$RC2_ROOT/SURRENDER.md" "${RC2_SURRENDER_TIMEOUT:-180}" "$prompt" | grep -oE '\{[^{}]*"verdict"[^{}]*\}' | head -1
}

# rc2_surrender_directive <rundir> <component> <primitive> <reason> — relay a REOPEN to the solver by
# bumping supervisor.md's tick (the solver already follows a newer SUPERVISOR_TICK; doctrine 00/10).
rc2_surrender_directive() {
  local rundir="$1" comp="$2" prim="$3" reason="$4" body
  body="$(printf '%s\n\n%s\n%s\n%s\n%s\n%s\n%s' \
    "_surrender gate rejected the blocker — a negative you pruned was under-tested_" \
    "STATUS: rabbit-hole" \
    "FOCUS: reopen-$comp" \
    "READ: you declared a blocker, but '$comp' was dismissed on thin evidence and could run at a higher privilege than you." \
    "GOOD: you did thoroughly refute the paths you actually tested." \
    "STOP: accepting the blocker; stop treating '$comp' as closed." \
    "DO NEXT: RE-OPEN $comp — try the elevation primitive: $prim. $reason. Record the result as a depth-tested negative or a new elevation path; do NOT re-drill paths already disproven to depth.")"
  rc2_write_supervisor "$rundir" "surrender-gate" "$body" >/dev/null
  printf '%s surrender-gate REOPEN %s via %s: %s\n' "$(rc2_utc)" "$comp" "$prim" "$reason" >> "$rundir/logs/guard.log" 2>/dev/null || true
}

# ── side process: supervisor (oversee), placed per the runtime ───────────────
# Inside herdr (HERDR_ENV=1) oversee runs in a sibling pane; otherwise a tmux session (default).
# NO_OVERSEE=1 skips it. Sets HERDR_OVERSEE_PANE (herdr) so cleanup can close it; else the tmux
# session is <tmux_base>_oversee. Needs $RC2_ROOT, $tmux_base.
rc2_launch_oversee() {
  local rundir="$1" slug; slug="$(basename "$rundir")"
  HERDR_OVERSEE_PANE=""
  [ "${NO_OVERSEE:-0}" = "1" ] && { echo "[oversee] disabled (NO_OVERSEE=1)"; return 0; }
  # pass the guard/gate env explicitly: a pre-existing tmux server would not inherit it otherwise
  local ocmd="RC2_GATE='${RC2_GATE:-}' RC2_GUARD='${RC2_GUARD:-off}' RC2_GATE_N='${RC2_GATE_N:-}' RC2_GATE_MODE='${RC2_GATE_MODE:-}' OVERSEE_INTERVAL='${OVERSEE_INTERVAL:-600}' scripts/oversee.sh '$slug'"
  if [ "${HERDR_ENV:-}" = "1" ] && command -v herdr >/dev/null 2>&1; then
    local p; p="$(herdr pane split --current --direction right --cwd "$RC2_ROOT" --no-focus 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null)"
    if [ -n "$p" ]; then
      herdr pane run "$p" "$ocmd" >/dev/null 2>&1
      HERDR_OVERSEE_PANE="$p"
      echo "[oversee] herdr pane $p (right split; herdr pane read $p to view)"
      return 0
    fi
    echo "[oversee] herdr pane split failed — falling back to tmux"
  fi
  tmux new-session -d -s "${tmux_base}_oversee" "cd '$RC2_ROOT' && $ocmd" 2>/dev/null \
    && echo "[oversee] tmux '${tmux_base}_oversee' (attach to watch; NO_OVERSEE=1 to disable)" || true
}

# Stop whatever rc2_launch_oversee started (herdr pane or tmux session).
rc2_stop_oversee() {
  if [ -n "${HERDR_OVERSEE_PANE:-}" ]; then herdr pane close "$HERDR_OVERSEE_PANE" 2>/dev/null || true
  else tmux kill-session -t "${tmux_base}_oversee" 2>/dev/null || true; fi
}
