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
