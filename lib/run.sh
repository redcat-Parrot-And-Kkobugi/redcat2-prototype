#!/usr/bin/env bash
# =============================================================================
#  run.sh — run-dir scaffold + (Stage C) prompt assembly and the resilient run
#  loop. Needs $RC2_ROOT and the resolve_target globals. Sourced via bootstrap.sh.
# =============================================================================

# Scaffold the run dir + seed the three living-memory files. Sets global RUNDIR, echoes it.
rc2_scaffold() {
  local slug; slug="$(printf '%s' "${MACHINE_NAME:-$TARGET_IP}" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_.-')"
  RUNDIR="$RC2_ROOT/runs/$slug"
  # FRESH=1 -> archive any existing run so this starts clean (old memory is kept, not deleted).
  if [ "${FRESH:-}" = "1" ] && [ -d "$RUNDIR" ]; then
    local bak="$RUNDIR.bak.$(date +%s)"; mv "$RUNDIR" "$bak"
    echo "[fresh] archived previous run -> $(basename "$bak")" >&2
  fi
  mkdir -p "$RUNDIR"/{recon,enum,loot/{hashes,keys,tickets,files},exploit,tools,bin,research,reversing,notes,logs/raw,tmp,.claude}
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
rc2_run_loop() {
  local attempt=0 rc
  local PRETTY=(cat); [ -f "$RC2_ROOT/scripts/conv_fmt.py" ] && PRETTY=(python3 "$RC2_ROOT/scripts/conv_fmt.py")
  while :; do
    attempt=$((attempt+1))
    [ "$attempt" -gt 1 ] && printf '\033[33m[hunt] relaunch %d/%d — resuming from disk memory\033[0m\n' "$attempt" "$MAX_RESTARTS" | tee -a "$LOG"
    claude -p "$PROMPT" \
      --output-format stream-json \
      --model "$MODEL" \
      --append-system-prompt "$SYSPROMPT" \
      --dangerously-skip-permissions \
      --verbose \
      > >(tee -a "$CONV" | "${PRETTY[@]}" >> "$LOG") 2>&1 &   # conv -> CONV (watch.sh renders it) + LOG; NOT the hunt terminal
    RUN_PID=$!          # global on purpose: cleanup() kills it
    rc=0; wait "$RUN_PID" || rc=$?   # errexit-safe: a non-zero agent exit must NOT abort the loop
    if rc2_both_flags "$RUNDIR"; then echo "[hunt] both flags captured — done." | tee -a "$LOG"; break; fi
    if [ "${NO_RESTART:-0}" = "1" ]; then echo "[hunt] NO_RESTART=1 — single run complete (rc=$rc)." | tee -a "$LOG"; break; fi
    if [ "$rc" -eq 0 ]; then echo "[hunt] agent stopped cleanly without both flags (blocker/stuck). Respecting it — not relaunching. Re-run ./hunt $TARGET to continue." | tee -a "$LOG"; break; fi
    if [ "$attempt" -ge "$MAX_RESTARTS" ]; then echo "[hunt] hit MAX_RESTARTS=$MAX_RESTARTS (last rc=$rc) — stopping." | tee -a "$LOG"; break; fi
    printf '\033[31m[hunt] agent exited rc=%s (crash/overflow) — will relaunch\033[0m\n' "$rc" | tee -a "$LOG"; sleep 3
  done
}

# ── periodic status snapshot ─────────────────────────────────────────────────
# rc2_write_status <rundir> — one machine-generated snapshot of the CURRENT situation into
# <rundir>/status.md (operator view + resume aid). Reads meta.env for start/elapsed. Safe anytime.
rc2_write_status() {
  local rundir="$1" L="$1/logs" tb now start elapsed
  [ -d "$rundir" ] || return 0
  now="$(date -u +%FT%TZ)"
  start="$( [ -f "$L/meta.env" ] && . "$L/meta.env" 2>/dev/null; echo "${start_epoch:-$(date +%s)}")"
  elapsed=$(( ($(date +%s) - start) / 60 ))
  tb="$( [ -f "$rundir/target.env" ] && . "$rundir/target.env" 2>/dev/null; echo "${tmux_base:-rc2}")"
  local mn ti os df
  mn="$( . "$rundir/target.env" 2>/dev/null; echo "${machine_name:-?}")"
  ti="$( . "$rundir/target.env" 2>/dev/null; echo "${target_ip:-?}")"
  os="$( . "$rundir/target.env" 2>/dev/null; echo "${os_hint:-?}")"
  df="$( . "$rundir/target.env" 2>/dev/null; echo "${difficulty:-?}")"
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
    echo "## journal (recent)"; tail -15 "$rundir/journal.md" 2>/dev/null | sed 's/^/  /'
    echo
    echo "## recent tool calls (last 15)"
    [ -f "$L/tools.jsonl" ] && tail -40 "$L/tools.jsonl" | jq -r 'select(.event=="post") | "- [\(.ts)] \(.tool) \((.command // "")[0:100]) (\(.out_bytes)B)"' 2>/dev/null | tail -15
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

# ── side process: supervisor (oversee), placed per the runtime ───────────────
# Inside herdr (HERDR_ENV=1) oversee runs in a sibling pane; otherwise a tmux session (default).
# NO_OVERSEE=1 skips it. Sets HERDR_OVERSEE_PANE (herdr) so cleanup can close it; else the tmux
# session is <tmux_base>_oversee. Needs $RC2_ROOT, $tmux_base.
rc2_launch_oversee() {
  local rundir="$1" slug; slug="$(basename "$rundir")"
  HERDR_OVERSEE_PANE=""
  [ "${NO_OVERSEE:-0}" = "1" ] && { echo "[oversee] disabled (NO_OVERSEE=1)"; return 0; }
  local ocmd="OVERSEE_INTERVAL='${OVERSEE_INTERVAL:-600}' scripts/oversee.sh '$slug'"
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
