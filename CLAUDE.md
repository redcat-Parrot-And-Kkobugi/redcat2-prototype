# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`redcat2` is an **autonomous offensive-research agent** that solves Hack The Box–style
machines of **every difficulty, Easy through Insane** (the design's edge shows most on the
hard ones). The engine is **Claude Code itself** (`claude -p` headless). The `./hunt`
launcher executes **real commands on the attack host** against the target. **Authorized
labs only** (HTB, your own range). Nothing is sandboxed.

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
run dir, whose three living-memory files carry all state. The disk *is* the memory.
`--fresh` archives the old run and starts clean. Within a run, a crash or context overflow
(non-zero exit) **auto-relaunches** a fresh headless agent that resumes from the three files
(`MAX_RESTARTS`, default 20); a clean exit (flags or a written blocker) is respected and not
relaunched. `NO_RESTART=1` runs exactly once. Watch any run live with `scripts/watch.sh`
(reasoning from `conv.jsonl` + every tool call/result from `tools.jsonl`).

`./hunt` (plumbing in `lib/`, loaded via `lib/bootstrap.sh` → `common/env/htb/run.sh`) loads
env, **refreshes the HTB token when stale** (`rc2_ensure_htb_token`: `rc2_import_har` copies
the newest `*.har` from `$HAR_SRC` — default the Windows DevTools folder — into `har/`, then
the bundled extractor writes a verified token to `.env`), resolves/spawns the box via the HTB
API, does a VPN pre-flight, scaffolds `runs/<slug>/`, starts `oversee.sh` alongside — a herdr
sibling pane if run inside herdr, else a `<tmux_base>_oversee` tmux session (unless `NO_OVERSEE=1`),
builds the system prompt by
concatenating `doctrine/*.md`, then launches `claude -p` with `--dangerously-skip-permissions`,
`--output-format stream-json`, and the doctrine as `--append-system-prompt`. A per-run hook
force-logs every tool call; a background watcher auto-submits captured flags. The whole
HAR → token → resolve/spawn → submit pipeline is hands-off and model-independent. On exit `hunt` runs `report.sh` (metrics → `writeup.md`) and
`analyze_run.sh` (failure classification → `failure_analysis.md/.json`). Optionally run
`scripts/oversee.sh <slug>` in a second terminal for a long-horizon supervisor.

## Architecture (the big picture)

The system has three layers; read them together:

- **The brain is `doctrine/` (prose, not code).** Seven Markdown files concatenated (in
  numeric order) into the system prompt — this is the entire methodology. It is intentionally
  **not** a playbook library. `00-prime-directive` (identity, hard rules, done-condition),
  `10-hunt-loop` (the ORIENT→RESEARCH→EXPERIMENT→OBSERVE→VERIFY→REFLECT cycle + rabbit-hole
  budgets), `20-research-and-dorking` (live-internet research as a first-class action; Google
  dork operators/recipes; exploit vetting), `30-interactive-and-tools` (tmux doctrine; install/
  build tools on the fly), `40-memory-and-state` (the three living files + run-dir layout),
  `50-subagents` (the team + when to delegate), `60-reversing` (IDA export-first + gdb-in-tmux).
  `hunt` concatenates `doctrine/*.md`, so a new file is picked up automatically. **To change
  how the agent thinks, edit a doctrine file** — not the launcher.

- **The team is `.claude/agents/*.md` (multi-model sub-agents).** The orchestrator (opus by
  default) delegates via the Task tool. `researcher` (sonnet) does web research + dorking;
  `recon-analyst` (haiku) distills walls of output into facts; `exploit-dev` (opus) writes/
  adapts exploit code; `verifier` (opus) adversarially checks wins and risky actions;
  `reverser` (opus) does export-first IDA binary analysis. Each is
  one file with frontmatter (`name`, `description`, `tools`, `model`) + a focused prompt.
  **Adding a specialist = adding one file.** The run dir symlinks this directory in so
  `claude -p` (cwd = run dir) sees the team.

- **The memory is the run dir — three living files the agent rewrites every loop.**
  `worldmodel.md` (only VERIFIED facts), `hypotheses.md` (the ranked attack board with
  per-hypothesis evidence budgets), `journal.md` (append-only decision trail). Raw evidence
  lives beside them under `recon/ enum/ loot/ exploit/ reversing/ research/ tools/ bin/ notes/
  logs/`. This is what lets a hunt outlive a single context window — the core requirement for
  Insane boxes. See `doctrine/40-memory-and-state.md` for the exact formats.

## Standalone — bundled plumbing

redcat2 depends on no sibling project. Everything it needs lives inside this tree (the HTB
plumbing was originally lifted from redcat1 but is now vendored and self-referential via
relative paths):
- **`.env`** — redcat2's own, the only env it reads. Holds `CLAUDE_CODE_OAUTH_TOKEN`,
  `HTB_TOKEN`, `SECLISTS_DIR`, `SUDO_PASS`, `HTB_OVPN`. The HAR automation writes `HTB_TOKEN`
  here. Gitignored.
- **`scripts/lib/htb_api.sh`** — HTB resolve/spawn/submit (v4 machine/vm, v5 own).
- **`tools/env-setting/set_token_from_har.sh`** + `check_token.sh` — the HAR → `aud:6` bearer
  extractor + validator, called by `rc2_ensure_htb_token`. Drop HARs in `redcat2/har/`.
- **`scripts/conv_fmt.py`** — pretty-renders the stream-json log (falls back to raw `cat`).

The only external resource is **SecLists** at `$SECLISTS` (default `~/files_etc/SecLists`), a
shared wordlist tree that is not part of any project. If the HTB API/token is absent,
`./hunt <ip>` still works in IP-only mode (no spawn/submit). Deleting `/home/kali/redcat` does
not affect redcat2.

## Terminals: tmux and herdr (division of labor)

**tmux is the default and does all in-box session work**, each per its need:
- **`<tmux_base>_main`** — long/progress tools the operator watches live.
- the agent's own interactive sessions it drives via `send-keys`: reverse shells, `msfconsole`,
  handlers, and the **`<tmux_base>_dbg`** gdb session.
- **`<tmux_base>_oversee`** — the supervisor loop (only when NOT inside herdr; see below).
tmux is zero-dependency and lives in the agent's shell env, so everything runs on it by default.
(The OpenVPN tunnel is a separate system daemon — `openvpn --daemon`, logged to `logs/openvpn.log`
— not a tmux session; it's shared infra and left up across hunts.)

**herdr** ([herdr.dev](https://herdr.dev) — a runtime for coding agents: persistent, status-aware
sessions, a socket API to coordinate agents, multi-machine over SSH) is the **outer / operator**
layer: run `./hunt` inside a herdr pane and it becomes herdr-aware — `rc2_launch_oversee` detects
`HERDR_ENV=1` and puts oversee in a **sibling pane** (`herdr pane split --current` + `pane run`)
instead of a tmux session; cleanup closes that pane. Outside herdr, oversee falls back to tmux.
herdr's *in-process* agent coordination overlaps Claude Code's native sub-agents (which redcat2
uses), so herdr is not used for that. herdr is installed here; the pane mechanics are verified.
Start it with `herdr` (TUI) or `herdr server` (headless), then run `./hunt` in a pane. tmux stays
the zero-dependency default for everything else.

## Conventions

- **Doctrine drives behavior.** Prefer editing `doctrine/*.md` over hardcoding steps in the
  launcher. The launcher is plumbing; the doctrine is policy.
- **Evidence discipline.** The doctrine forbids recording unverified wins and forbids grinding
  (per-hypothesis evidence budgets → freeze + switch). Preserve this when editing — it is the
  main defense against the rabbit holes Insane boxes are built from.
- **Secrets.** `.env`, `runs/`, `*.ovpn`, keys, HARs are gitignored. Never put a password on a
  command line (it's hook-logged); root actions use `sudo -A` via the wired askpass.
- Temp/scratch for development goes in `tmp/`; per-run temp is `runs/<slug>/tmp` (`TMPDIR`).
- **Helper scripts** (`scripts/`): `watch.sh` (live run viewer); `oversee.sh` (supervisor/
  critic → `supervisor.md`, auto-started by `hunt` — a herdr sibling pane inside herdr, else a
  `<tmux_base>_oversee` tmux session);
  `report.sh` + `analyze_run.sh` (retrospectives, auto-run by `hunt` on exit → `writeup.md`,
  `failure_analysis.md/.json`); `rag.sh` (cross-run memory over past runs); `machine.sh` (HTB
  API util: info/ip/spawn/active/stop/reset/submit by name, name→id auto, 15×3 min spawn wait);
  `burp.sh up|status|down` (optional Burp-over-MCP, opt-in before `./hunt`); `install_tools.sh`
  (one-shot Kali toolset); `conv_fmt.py` (stream-json renderer).
- **Live state.** `hunt` runs two background loops: `rc2_flag_watcher` (auto-submits flags) and
  `rc2_status_writer` (rewrites `status.md` every `STATUS_INTERVAL`, default 600s — flags, phase,
  hypothesis counts, journal tail, recent tools, tmux, artifact counts). The HTB spawn/IP wait is
  15 tries × 180s = 45 min (`IP_WAIT_TRIES`/`IP_WAIT_INTERVAL`); shorten via env for fast boxes.
- **Oversight.** `oversee.sh` runs an opus reviewer that writes `supervisor.md` only on drift; the
  solver follows a newer `SUPERVISOR_TICK` (doctrine `10-hunt-loop.md`). Its system prompt is
  `OVERSEER.md` (kept out of `doctrine/` so it never enters the solver's own prompt).
- **Reversing** is export-first (`doctrine/60-reversing.md`): IDA → files under `reversing/`,
  grep locally, query IDA MCP only surgically; gdb runs in a `<tmux_base>_dbg` tmux session,
  launched with a plugin via the on-PATH wrappers `gdb-pwndbg` (default) / `gdb-gef` / `gdb-peda`
  (or `init-pwndbg`/`init-gef`/`init-peda` inside gdb). No plugin auto-loads — pick one per session.
