# redcat2 — Full Guide

An autonomous offensive-research agent for Hack The Box–style machines (Easy → Insane).
The engine is Claude Code headless (`claude -p`); the intelligence is a compact **doctrine**
that makes the agent reason like a researcher — observe → hypothesize → research → experiment
→ verify → reflect — rather than run a playbook. **Authorized labs only.** `./hunt` executes
real commands against the target with `--dangerously-skip-permissions`.

- [1. Quick start](#1-quick-start)
- [2. One-time setup](#2-one-time-setup)
- [3. The `hunt` command + env toggles](#3-the-hunt-command--env-toggles)
- [4. How it thinks (the Hunt Loop + doctrine)](#4-how-it-thinks)
- [5. Sub-agents](#5-sub-agents)
- [6. The run directory & living memory](#6-the-run-directory--living-memory)
- [7. Every script](#7-every-script)
- [8. tmux & herdr](#8-tmux--herdr)
- [9. Reversing (IDA + gdb)](#9-reversing-ida--gdb)
- [10. Resume, restart, fresh](#10-resume-restart-fresh)
- [11. Observability](#11-observability)
- [12. Security & safety](#12-security--safety)
- [13. Troubleshooting](#13-troubleshooting)
- [14. Extending](#14-extending)
- [15. File map](#15-file-map)

---

## 1. Quick start

```bash
cd /home/kali/redcat2
cp .env.example .env                 # fill CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)
./hunt Blizzard                      # HTB name → resolve/spawn → run (opus orchestrator)
./hunt 10.10.11.42 sonnet "web on 443 looks custom"   # raw IP + cheaper model + a hint
```

Watch it live in a second terminal: `scripts/watch.sh`. Re-run the same target to resume.
Everything else — HTB token refresh from a HAR, machine spawn, VPN, supervisor, status
snapshots, flag submission, end-of-run report — is automatic.

---

## 2. One-time setup

### `.env` (gitignored — never committed)
Copy `.env.example` → `.env` and fill:

| key | needed for | how to get it |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | **required** — the agent engine | `claude setup-token` |
| `HTB_TOKEN` | name resolve, spawn, flag submit | auto from a HAR (below); optional for IP-only |
| `SECLISTS_DIR` | wordlists (`$SECLISTS`) | path to SecLists (default `~/files_etc/SecLists`) |
| `SUDO_PASS` | non-interactive `sudo -A` (apt/VPN/hosts) | your sudo password (optional) |
| `HTB_OVPN` | auto VPN connect | path to your HTB `.ovpn` (optional) |
| `BURP_MCP_TOKEN` | optional Burp-over-MCP | BurpMCP-Ultra Server tab (optional) |
| `HAR_SRC` | where HARs are dropped | default `/mnt/c/Users/Godjs/Desktop/tmp/htb-api-har` |

`.env` must be LF line endings (a stray CR corrupts tokens).

### HTB token (hands-off)
Log in to `app.hackthebox.com`, open DevTools → Network → **Save all as HAR**, drop it in your
`HAR_SRC` folder. When the labs token is missing/expired, `./hunt` copies the newest HAR into
`har/`, extracts + verifies the `aud:6` bearer, and writes it to `.env`. Manual equivalents:
`tools/env-setting/set_token_from_har.sh <file.har>` and `tools/env-setting/check_token.sh`.

### Tooling
- `scripts/install_tools.sh` — one-shot Kali toolset (`core` = apt only, `max` = + pipx/go/git/
  SecLists/files_etc, `--check` = report what's present). On-demand install during a hunt is the
  norm; this is just convenience.
- **IDA Pro 9.3** — install yourself + the `ida-pro-mcp` server. `~/.local/bin/{ida,idat}` wrappers
  point at the install (and `ida64`/`idat64` aliases).
- **gdb plugins** — installed via `gdb-plugin-relative-installer`; launchers on PATH:
  `gdb-pwndbg` / `gdb-gef` / `gdb-peda` (see §9).
- **herdr** (optional) — `curl -fsSL https://herdr.dev/install.sh | sh`; run `./hunt` inside it
  for a persistent, status-aware operator workspace (see §8).
- **Burp** (optional) — `scripts/burp.sh up` before `./hunt` for `mcp__burp__*`.

---

## 3. The `hunt` command

```
./hunt [--fresh] <machine_name|ip> [orchestrator_model] [extra notes]
```

- **`<machine_name|ip>`** — an HTB name (resolved + spawned via the API; needs a token) or a raw
  IP (IP-only mode: no spawn/submit).
- **`[orchestrator_model]`** — the orchestrator model; default `opus`. Sub-agents pick their own.
- **`[extra notes]`** — free-text hint appended to the launch prompt.
- **`--fresh`** — archive any existing run for this target and start clean.

### Environment toggles

| var | default | effect |
|---|---|---|
| `MAX_RESTARTS` | 20 | auto-relaunch budget on crash/overflow |
| `NO_RESTART` | 0 | `1` = run the agent once, no auto-relaunch |
| `NO_OVERSEE` | 0 | `1` = don't start the supervisor |
| `NO_STOP` | 0 | `1` = on solve, don't terminate the HTB machine (keep the box up) |
| `OVERSEE_INTERVAL` | 600 | supervisor review cadence (s) |
| `STATUS_INTERVAL` | 600 | `status.md` snapshot cadence (s) |
| `FLAG_INTERVAL` | 300 | flag auto-submit watcher poll cadence (s) |
| `IP_WAIT_TRIES` | 15 | spawn/IP poll attempts |
| `IP_WAIT_INTERVAL` | 180 | seconds between IP polls (15×180s = 45 min) |
| `HAR_SRC` | Windows DevTools folder | where to import the newest HAR from |
| `FRESH` | — | same as `--fresh` |

### Launch sequence (what `./hunt` does)
load `.env` → refresh HTB token from newest HAR if stale → resolve/spawn the box (wait up to 15×3 min) →
VPN pre-flight (`openvpn --daemon` if `HTB_OVPN` set) → scaffold `runs/<slug>/` → start the flag
auto-submitter, the `status.md` writer, and the supervisor (herdr pane or tmux) → build the
system prompt from `doctrine/*.md` → run `claude -p` in the resilient loop → on exit write
`writeup.md` + `failure_analysis.*` and a final `status.md`. **On a solve** (both flags) it also
**terminates the HTB machine** (unless `NO_STOP=1`) and tears down the run's tmux sessions;
otherwise state is preserved for resume.

---

## 4. How it thinks

The brain is `doctrine/*.md`, concatenated (00→60) into the system prompt. It is **not** a
playbook library. The loop:

```
  +---------------------------------------------------------------------+
  | 1. ORIENT     pick the best hypothesis (confidence x impact / cost) |
  | 2. RESEARCH?  learn whatever you don't know cold, before acting     |
  | 3. EXPERIMENT run the smallest test that moves that hypothesis      |
  | 4. OBSERVE    capture the full, raw evidence                        |
  | 5. VERIFY     prove it truly happened (independent check)           |
  | 6. REFLECT    update the board, re-rank, freeze dead ends           |
  +-------------------------------- loop until user.txt + root.txt <----+
```

| doctrine file | what it governs |
|---|---|
| `00-prime-directive` | identity, hard rules, done-condition, effort-scaling by difficulty |
| `10-hunt-loop` | the loop, evidence budgets, rabbit-hole freeze, external supervisor |
| `20-research-and-dorking` | live-internet research, Google dork recipes, exploit vetting, `rag.sh` recall |
| `30-interactive-and-tools` | tmux sessions, install/build tools on the fly, visual handling |
| `40-memory-and-state` | the three living files + run-dir layout; auto files are read-only |
| `50-subagents` | the team + when to delegate |
| `60-reversing` | IDA export-first + gdb-in-tmux |

Core disciplines: **evidence over belief** (no unverified wins), **research before acting on the
unknown** (read exploit code first), **no grinding** (each hypothesis has an evidence budget; on
exhaustion it freezes and the agent switches). To change behavior, edit a doctrine file — not the
launcher.

---

## 5. Sub-agents

Claude Code native sub-agents in `.claude/agents/`, each on a model suited to its job. The
orchestrator (opus) delegates via the Task tool.

| agent | model | use for |
|---|---|---|
| `researcher` | sonnet | live-internet research + Google dorking; returns a vetted, target-matched brief |
| `recon-analyst` | haiku | distilling walls of output (nmap, dirb, source dumps) into facts |
| `exploit-dev` | opus | writing/adapting exploit code, payloads, chains; debugging a failed payload |
| `verifier` | opus | adversarial check of a claimed win or a risky/one-shot action before committing |
| `reverser` | opus | export-first IDA binary analysis; returns the primitives that matter |

Add a specialist = add one `.claude/agents/<name>.md` (frontmatter: name, description, tools, model).

---

## 6. The run directory & living memory

`runs/<slug>/` is the agent's cwd and memory. The **slug is the real machine name with its case
preserved** (e.g. `runs/Management`); spaces become `_` and other unsafe characters are dropped. An
IP target uses the IP as the slug. `tmux_base` is `rc2_<slug>`.

The **three living files** are rewritten every loop:

- `worldmodel.md` — only VERIFIED facts (access, creds, services, topology), each with provenance.
- `hypotheses.md` — the ranked attack board; one block per hypothesis with preconditions,
  evidence, confidence/impact/cost, next experiment, and an evidence budget.
- `journal.md` — append-only decision trail (what/why/result/next). The anti-rabbit-hole record.

Raw evidence and auto files alongside:

```
target.env   recon/ enum/ loot/ exploit/ reversing/ research/ tools/ bin/ notes/
flags.txt    user=<hex> / root=<hex>  (auto-submitted; see §11)
status.md    auto snapshot every ~10 min (read-only to the agent)
writeup.md   metrics (report.sh, on exit)
failure_analysis.md/.json   why the run went as it did (analyze_run.sh, on exit)
supervisor.md   reviewer verdicts, when oversee is running
logs/        conv.jsonl (full conversation), tools.jsonl + raw/ (every tool call),
             system_prompt.txt, meta.env, phases.log, flag_submit.log, session_*.log
.claude/     settings.json (logging hook) + agents → ../../.claude/agents
```

Resume reads, in order: `worldmodel.md` → `hypotheses.md` → tail of `journal.md` → `flags.txt`.

---

## 7. Every script

Run from the repo root. Most take a run slug/name/IP, defaulting to the newest run.

| script | usage | what it does |
|---|---|---|
| `hunt` | `./hunt [--fresh] <name|ip> [model] [notes]` | the launcher (§3) |
| `scripts/watch.sh` | `scripts/watch.sh [name]` | live feed: agent reasoning + every tool call/result. `FULL=1` whole outputs, `NOCONV=1` tool-feed only, `MAX=<n>` lines |
| `scripts/oversee.sh` | `scripts/oversee.sh <slug> ["directive"]` | supervisor/critic loop → `supervisor.md` on drift. `OVERSEE_INTERVAL`, `OVERSEE_MODEL`, `ONESHOT=1`. Auto-started by `hunt` |
| `scripts/report.sh` | `scripts/report.sh <rundir>` | metrics → `writeup.md` (wall time, tool/Task counts, per-phase). Auto on exit |
| `scripts/analyze_run.sh` | `scripts/analyze_run.sh [rundir|name]` | failure classifier → `failure_analysis.md/.json`. Auto on exit |
| `scripts/rag.sh` | `scripts/rag.sh [-p] <query>` | cross-run memory: grep your own past runs. `-p` also searches PayloadsAllTheThings/GTFOBins. `SCOPE=runs/<slug>` to narrow |
| `scripts/machine.sh` | `scripts/machine.sh <cmd> <name|id> [flag]` | HTB API util: `info` / `ip` / `spawn` / `active` / `stop` / `reset` / `submit`. Names resolve to ids |
| `scripts/burp.sh` | `scripts/burp.sh up|status|down|restart` | optional Burp headless over MCP; registers `mcp__burp__*`. Needs `BURP_MCP_TOKEN` |
| `scripts/install_tools.sh` | `scripts/install_tools.sh [core|max|--check]` | install the Kali toolset |
| `scripts/auto_pr.sh` | (Stop hook) | on a file-changing turn: branch → commit → push → PR → merge to `main` via `gh`. No-op on a clean tree. `AUTO_PR_DISABLE=1`, `AUTO_PR_MERGE`, `AUTO_PR_MODEL`. Dev-workflow only — nothing to do with a hunt. See [TOOLS.md](TOOLS.md) |
| `scripts/conv_fmt.py` | (internal) | renders `claude -p` stream-json into a readable transcript |
| `scripts/lib/htb_api.sh` | `scripts/lib/htb_api.sh {profile|active|spawn|terminate|reset|own}` | raw HTB API client (sourceable or CLI) |
| `tools/env-setting/set_token_from_har.sh` | `… <file.har>` | extract + verify the labs token from a HAR → `.env` |
| `tools/env-setting/check_token.sh` | `…` | validate the current token/env against the live API |

Library (sourced, not run directly): `lib/bootstrap.sh` (loader), `lib/common.sh` (colors,
run-dir resolve, time), `lib/env.sh` (.env, flags), `lib/htb.sh` (token/resolve/spawn/VPN/
watcher), `lib/run.sh` (scaffold, prompts, run loop, status writer, oversee launch),
`lib/hook_log.sh` (per-tool-call logging hook + anti-DoS repeat guard).

**Full per-tool usage** — every flag, env knob, and example for the above — is in
[`docs/TOOLS.md`](TOOLS.md). This table is the index; that file is the reference.

---

## 8. tmux & herdr

Each is used per its need.

- **tmux** (zero-dependency, default) — all in-box sessions: `<tmux_base>_main` (long/progress
  tools you watch), the agent's own interactive sessions it drives with `send-keys` (reverse
  shells, `msfconsole`, handlers, the `<tmux_base>_dbg` gdb session), and `<tmux_base>_oversee`
  (supervisor, when not inside herdr). `tmux_base` is `rc2_<slug>`.
- **herdr** (optional outer/operator runtime) — run `./hunt` inside a herdr pane and it becomes
  herdr-aware: oversee goes in a **sibling pane** (`herdr pane split` + `pane run`) instead of a
  tmux session, giving a persistent, status-aware, disconnect-surviving workspace, and
  multi-machine over SSH. Start with `herdr` (TUI) or `herdr server` (headless), then `./hunt` in
  a pane. Its in-process agent coordination overlaps Claude Code sub-agents, so it's not used for
  that.
- **VPN** is a separate `openvpn --daemon` (shared infra, left up across hunts) — not a terminal
  session.

---

## 9. Reversing (IDA + gdb)

**Static — IDA, export-first.** Don't interrogate IDA function-by-function over MCP. Bulk-export
Hex-Rays pseudocode + strings/imports to `reversing/<binary>/` once, `grep`/`rg` those files
locally for logic and secrets, then query the IDA MCP only for targeted follow-ups (xrefs, one
re-decompile). The `reverser` sub-agent owns this and returns just the primitives. Launchers:
`ida` (GUI), `idat` (text) via `~/.local/bin` wrappers.

**Dynamic — gdb in a tmux `<tmux_base>_dbg` session.** No plugin auto-loads; pick one per session:

| launcher (on PATH) | plugin | inside gdb |
|---|---|---|
| `gdb-pwndbg` (default) | pwndbg | `init-pwndbg` |
| `gdb-gef` | GEF | `init-gef` |
| `gdb-peda` (+ `-intel`/`-arm`) | PEDA | `init-peda` |

Drive it with `tmux send-keys` and read back with `tmux capture-pane`. Debug a local copy, then
drive the real service with the exploit `exploit-dev` builds.

---

## 10. Resume, restart, fresh

- **Resume (implicit):** re-run `./hunt <target>` — it re-enters the run dir and continues from the
  three living files. The disk is the memory.
- **Auto-relaunch:** within a run, a crash or context overflow (non-zero exit) relaunches a fresh
  headless agent that resumes from disk, up to `MAX_RESTARTS` (default 20). A clean exit (flags, or
  a written blocker) is respected and not relaunched. `NO_RESTART=1` runs once.
- **Fresh:** `./hunt --fresh <target>` archives the old run to `runs/<slug>.bak.<epoch>` and starts
  clean.

---

## 11. Observability

- **Live feed:** `scripts/watch.sh` (second terminal) — reasoning + every command and result.
  The main `./hunt` terminal stays quiet: it shows only launch chrome (token/htb/vpn/oversee/
  banner) and the exit summary (report/analyze/stopped). The agent conversation goes to
  `logs/conv.jsonl` (rendered live by `watch.sh`) and `logs/session_*.log`, not your terminal.
- **Supervisor:** `oversee.sh` (auto) writes `supervisor.md` only when it sees drift; the solver
  follows a newer `SUPERVISOR_TICK`. Pass an operator directive: `scripts/oversee.sh <slug> "…"`.
- **Flag auto-submit:** `rc2_flag_watcher` (auto, every `FLAG_INTERVAL` s — default 300 = 5 min) submits user/root flags to HTB through
  two channels — the `user=`/`root=` lines the agent writes to `flags.txt`, **and** an enforced scan
  of logged `user.txt`/`root.txt` reads (from `logs/tools.jsonl` + `logs/raw/`), so a captured flag
  is submitted even if the agent never updated `flags.txt`. Dedup is persistent (`logs/.submitted`);
  an auth-rejected submit is left unmarked and retried next tick (e.g. after a token refresh). Every
  attempt is logged to `logs/flag_submit.log`. IP-only runs (no token/`machine_id`) skip submission.
- **Status snapshot:** `status.md` refreshed every `STATUS_INTERVAL` — flags, phase, hypothesis
  counts, journal tail, recent tools, tmux sessions, artifact counts.
- **Retrospective (on exit):** `writeup.md` (metrics) and `failure_analysis.md/.json` (why it
  stalled: tool-execution / state-mgmt / planning / hypothesis / idle-wait).
- **Full logs:** `logs/conv.jsonl` (complete conversation), `logs/tools.jsonl` + `logs/raw/`
  (every tool call, forced by the hook).

---

## 12. Security & safety

- **Scope:** acts only against the one `target_ip`. Authorized labs only. Runs with
  `--dangerously-skip-permissions` — point it only at hosts you may test.
- **Secrets stay local.** `.env`, `har/`, `runs/`, `*.ovpn`, keys are gitignored; only
  `.env.example` (empty) is tracked. The repo is private. Never commit a real token.
- **Passwords never hit a command line.** Root actions use `sudo -A` via an askpass helper that
  reads `$SUDO_PASS` from the environment, so the logging hook can't capture it. (Note:
  `SUDO_PASS=kali` is the Kali default — change it on a real host.)
- **Target-safety guard:** the hook blocks an identical scan command that keeps returning the
  identical result (stuck/throttle/DoS), and reverse-shell listeners are exempt.
- **Untrusted inputs:** downloaded exploits/binaries live in their own dir, are read before
  running, and are passed as arguments — never executed from inside their directory.

---

## 13. Troubleshooting

| symptom | fix |
|---|---|
| `set CLAUDE_CODE_OAUTH_TOKEN …` | run `claude setup-token`, put it in `.env` |
| name target rejected / token dead | drop a fresh HAR in `HAR_SRC`; `./hunt` re-imports, or run `tools/env-setting/check_token.sh` |
| no IP after spawn | box still booting; it waits 15×3 min=45 min, then set `target_ip` in `runs/<slug>/target.env` and re-run |
| no route to target | set `HTB_OVPN` in `.env`, or `sudo openvpn <file> &` |
| agent keeps restarting | it's crashing/overflowing; check `logs/session_*.log`; `NO_RESTART=1` to stop the loop |
| supervisor burning tokens | `NO_OVERSEE=1 ./hunt …` or raise `OVERSEE_INTERVAL` |
| Burp tools missing | `scripts/burp.sh up` before `./hunt`; needs `BURP_MCP_TOKEN` |
| gdb has no pwndbg/gef | launch `gdb-pwndbg`/`gdb-gef`, or `init-pwndbg` inside gdb |

---

## 14. Extending

- **Change behavior** → edit a `doctrine/*.md` file (it's the system prompt).
- **Add a specialist model/role** → add `.claude/agents/<name>.md`.
- **Add plumbing** → a function in the right `lib/*.sh`, wired in `hunt`; a standalone helper in
  `scripts/`. Nothing assumes HTB beyond `lib/htb.sh` + `scripts/lib/htb_api.sh`.
- **Workflow:** changes land via a feature branch → PR → squash-merge (commits are unsigned).
  Optionally automated: `scripts/auto_pr.sh` wired as a Claude Code **Stop hook** (in a personal,
  gitignored `.claude/settings.local.json`) does the branch → PR → merge for every file-changing
  turn. It only activates after a session reload (`/hooks` or restart), since the settings watcher
  wasn't watching `.claude/` at startup. See [`docs/TOOLS.md`](TOOLS.md).

---

## 15. File map

```
redcat2/
  hunt                      launcher
  CLAUDE.md README.md OVERSEER.md .env.example .gitignore
  docs/GUIDE.md docs/TOOLS.md   this guide + the full per-tool reference
  doctrine/00..60           the brain (system prompt)
  .claude/agents/           researcher recon-analyst exploit-dev verifier reverser
  .claude/settings.local.json   personal auto-PR Stop hook       (gitignored)
  lib/                      bootstrap common env htb run hook_log
  scripts/                  watch oversee report analyze_run rag machine burp install_tools conv_fmt auto_pr
  scripts/lib/htb_api.sh    HTB API client
  tools/env-setting/        set_token_from_har check_token
  har/                      drop HARs here            (gitignored)
  runs/<slug>/              per-box workspace + memory (gitignored)
```
