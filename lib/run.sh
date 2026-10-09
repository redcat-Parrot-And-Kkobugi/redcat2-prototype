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
      > >(tee -a "$CONV" | "${PRETTY[@]}" | tee -a "$LOG") 2>&1 &
    RUN_PID=$!          # global on purpose: cleanup() kills it
    wait "$RUN_PID"; rc=$?
    if rc2_both_flags "$RUNDIR"; then echo "[hunt] both flags captured — done." | tee -a "$LOG"; break; fi
    if [ "${NO_RESTART:-0}" = "1" ]; then echo "[hunt] NO_RESTART=1 — single run complete (rc=$rc)." | tee -a "$LOG"; break; fi
    if [ "$rc" -eq 0 ]; then echo "[hunt] agent stopped cleanly without both flags (blocker/stuck). Respecting it — not relaunching. Re-run ./hunt $TARGET to continue." | tee -a "$LOG"; break; fi
    if [ "$attempt" -ge "$MAX_RESTARTS" ]; then echo "[hunt] hit MAX_RESTARTS=$MAX_RESTARTS (last rc=$rc) — stopping." | tee -a "$LOG"; break; fi
    printf '\033[31m[hunt] agent exited rc=%s (crash/overflow) — will relaunch\033[0m\n' "$rc" | tee -a "$LOG"; sleep 3
  done
}
