# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`redcat2` is an **autonomous offensive-research agent** that solves Hack The Box–style
machines, targeting **Insane-tier and above**. The engine is **Claude Code itself**
(`claude -p` headless). The `./hunt` launcher executes **real commands on the attack host**
against the `--target`. **Authorized labs only** (HTB, your own range). Nothing is sandboxed.

redcat2 is a deliberate break from its predecessor (`/home/kali/redcat`, "redcat1"), which
followed a fixed 8-phase pipeline + per-service playbooks and stalled when a box needed
something off-script. redcat2 replaces that **procedural, technique-combination** approach
with an **epistemic one**: observe → hypothesize → research → experiment → verify → reflect,
looping until the flags fall. The agent reasons from evidence and live research, not a recipe.

## How it runs

```bash
./hunt <machine_name|ip> [orchestrator_model] [notes]
  ./hunt Blizzard                      # HTB API resolves/spawns; opus orchestrator
  ./hunt 10.10.11.42 opus "web app on 443 looks custom"
  ./hunt Blizzard sonnet               # cheaper orchestrator
```

Resume is **automatic and implicit**: re-launching the same target re-enters the existing
run dir, whose three living-memory files carry all state. There is no separate resume flag —
the disk *is* the memory.

`./hunt` (see `lib/bootstrap.sh`) loads env, resolves/spawns the box via the HTB API, does a
VPN pre-flight, scaffolds `runs/<slug>/`, builds the system prompt by concatenating
`doctrine/*.md`, then launches `claude -p` with `--dangerously-skip-permissions`,
`--output-format stream-json`, and the doctrine as `--append-system-prompt`. A per-run hook
force-logs every tool call; a background watcher auto-submits flags.

## Architecture (the big picture)

The system has three layers; read them together:

- **The brain is `doctrine/` (prose, not code).** Six Markdown files concatenated into the
  system prompt — this is the entire methodology. It is intentionally **not** a playbook
  library. `00-prime-directive` (identity, hard rules, done-condition), `10-hunt-loop` (the
  ORIENT→RESEARCH→EXPERIMENT→OBSERVE→VERIFY→REFLECT cycle + rabbit-hole budgets),
  `20-research-and-dorking` (live-internet research as a first-class action; Google dork
  operators/recipes; exploit vetting), `30-interactive-and-tools` (tmux doctrine; install/
  build tools on the fly), `40-memory-and-state` (the three living files + run-dir layout),
  `50-subagents` (the team + when to delegate). **To change how the agent thinks, edit a
  doctrine file** — not the launcher.

- **The team is `.claude/agents/*.md` (multi-model sub-agents).** The orchestrator (opus by
  default) delegates via the Task tool. `researcher` (sonnet) does web research + dorking;
  `recon-analyst` (haiku) distills walls of output into facts; `exploit-dev` (opus) writes/
  adapts exploit code; `verifier` (opus) adversarially checks wins and risky actions. Each is
  one file with frontmatter (`name`, `description`, `tools`, `model`) + a focused prompt.
  **Adding a specialist = adding one file.** The run dir symlinks this directory in so
  `claude -p` (cwd = run dir) sees the team.

- **The memory is the run dir — three living files the agent rewrites every loop.**
  `worldmodel.md` (only VERIFIED facts), `hypotheses.md` (the ranked attack board with
  per-hypothesis evidence budgets), `journal.md` (append-only decision trail). Raw evidence
  lives beside them under `recon/ enum/ loot/ exploit/ research/ tools/ bin/ notes/ logs/`.
  This is what lets a hunt outlive a single context window — the core requirement for Insane
  boxes. See `doctrine/40-memory-and-state.md` for the exact formats.

## Reused from redcat1 (`$RC1_DIR`, default `/home/kali/redcat`)

redcat2 owns its brain but borrows redcat1's proven plumbing, resolved at launch by
`lib/bootstrap.sh`:
- **`.env`** — tokens are read from `redcat2/.env` if present, else `$RC1_DIR/.env`.
- **`scripts/lib/htb_api.sh`** — sourced for HTB resolve/spawn/submit (v4 machine/vm, v5 own).
- **SecLists** (`$SECLISTS`) and other `files_etc` resources.
- **`scripts/conv_fmt.py`** — used to pretty-render the stream-json log if present.

Set `RC1_DIR` to point elsewhere. If the HTB API/token is absent, `./hunt <ip>` still works
in IP-only mode (no spawn/submit).

## Why tmux, not herdr

herdr.dev (a background runtime for coding agents: persistent panes, working/blocked/idle
status, a socket API to spawn and coordinate *other* agents) was evaluated and **not
adopted**. Its coordination features overlap with Claude Code's native sub-agents (used here),
and it would add a pre-1.0 socket dependency; tmux already handles the one real need —
holding long-lived interactive target sessions (reverse shells, `msfconsole`, ssh/su). herdr
remains a candidate only if multi-machine/distributed operation is ever wanted.

## Conventions

- **Doctrine drives behavior.** Prefer editing `doctrine/*.md` over hardcoding steps in the
  launcher. The launcher is plumbing; the doctrine is policy.
- **Evidence discipline.** The doctrine forbids recording unverified wins and forbids grinding
  (per-hypothesis evidence budgets → freeze + switch). Preserve this when editing — it is the
  main defense against the rabbit holes Insane boxes are built from.
- **Secrets.** `.env`, `runs/`, `*.ovpn`, keys, HARs are gitignored. Never put a password on a
  command line (it's hook-logged); root actions use `sudo -A` via the wired askpass.
- Temp/scratch for development goes in `tmp/`; per-run temp is `runs/<slug>/tmp` (`TMPDIR`).
