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

The full operator reference — setup, every command and flag, every script, tmux,
reversing, resume, observability, and troubleshooting — is `docs/GUIDE.md` (and `README.md`).
The **design rationale** — the whole pipeline, why it is shaped this way, the guard's failure-mode
model, the data model, and the invariants (with ASCII diagrams) — is `docs/DEVELOPER.md`.
This file is the orientation for working *on* the codebase.

## How it runs

```bash
./hunt <machine_name|ip> [orchestrator_model] [notes]
  ./hunt Blizzard                      # HTB API resolves/spawns; Opus 4.8 orchestrator
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

`./hunt` (plumbing in `lib/`, loaded via `lib/bootstrap.sh` → `common/tools_log/env/htb/run.sh`) loads
env, **refreshes the HTB token when stale** (`rc2_ensure_htb_token`: `rc2_import_har` copies
the newest `*.har` from `$HAR_SRC` — default the Windows DevTools folder — into `har/`, then
the bundled extractor writes a verified token to `.env`), resolves/spawns the box via the HTB
API, does a VPN pre-flight, scaffolds `runs/<slug>/`, starts `oversee.sh` alongside in a
`<tmux_base>_oversee` tmux session (unless `NO_OVERSEE=1`) —
and likewise `auditor.sh` (the epistemic auditor; unless `NO_AUDITOR=1`),
builds the system prompt by
concatenating `doctrine/*.md`, then launches `claude -p` with `--dangerously-skip-permissions`,
`--output-format stream-json`, and the doctrine as `--append-system-prompt`. A per-run hook
(`lib/hook_log.sh`, registered in `<run>/.claude/settings.json`) force-logs every tool call and
its full result independent of model behavior, and blocks (exit 2) identical-command/identical-result
repeats to guard the target against a stuck/throttle/DoS loop; a background watcher auto-submits
captured flags. The whole
HAR → token → resolve/spawn → submit pipeline is hands-off and model-independent. The default
orchestrator model is **Opus 4.8** (`claude-opus-4-8`); pass a 2nd arg to override. `rc2_pin_model`
(`lib/env.sh`) then **caps opus at 4.8** — a bare `opus` alias (resolves to newest = 5.x) or any
`claude-opus-5+` id is pinned to `claude-opus-4-8`, while sonnet/haiku and `claude-opus-4-*` pass through
unchanged — because the real-time cyber safeguard trips hardest on Claude-5 opus (escape hatches:
`RC2_NO_PIN=1`, `RC2_PIN_MODEL`). Relaunch/sub-agent re-spawn cost is cut by **server-side prompt caching**
set to a 1h TTL (`CLAUDE_CODE_PROMPT_CACHE_TTL` / `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL`, `lib/env.sh`): the
byte-stable doctrine prefix is reused across relaunches within the window (OAuth-only, so `ANTHROPIC_API_KEY`
stays unset). On exit `hunt`
runs `report.sh` (writeup narrative + metrics → `writeup.md`) and `analyze_run.sh` (failure
classification → `failure_analysis.md/.json`); on a **solve** it also **terminates the HTB machine**
(unless `NO_STOP=1`) and tears down the run's tmux. Optionally run `scripts/oversee.sh <slug>` in a
second terminal for a long-horizon supervisor.

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
  `claude -p` (cwd = run dir) sees the team. The opus agents (`exploit-dev`, `verifier`, `reverser`) are
  pinned to `claude-opus-4-8` in their frontmatter; `researcher` stays `sonnet` and `recon-analyst` `haiku`
  (only opus is capped — see model pinning above). The sameness-judge (`GUARD_JUDGE_MODEL`) is `sonnet`;
  the surrender gate (`RC2_SURRENDER_MODEL`) and oversee (`OVERSEE_MODEL`) are `claude-opus-4-8`.

- **The memory is the run dir — three living files the agent rewrites every loop.**
  `worldmodel.md` (only VERIFIED facts), `hypotheses.md` (the ranked attack board with
  per-hypothesis evidence budgets), `journal.md` (append-only decision trail), plus `ledger.json` —
  the machine-readable mirror of the board that the **guard** reads (the solver keeps it in sync;
  counters/arbiter-freezes live in the harness-owned `logs/accounting.json`). Raw evidence
  lives beside them under `recon/ enum/ loot/ exploit/ reversing/ research/ tools/ bin/ notes/
  logs/ cache/` (`cache/` is run-local scratch only — NOT Claude's config/cache). Auto-written,
  read-only companions: `status.md` (operator dashboard), `target_health.md` (live UP/DOWN/MOVED box
  signal from `rc2_health_watcher`), and `journal.archive.md` (entries rolled out of `journal.md` to
  keep resume cheap — history, never re-read on resume). This is what lets a hunt outlive a single
  context window — the core requirement for Insane boxes. See `doctrine/40-memory-and-state.md` for the
  exact formats (incl. the explicit **resume kernel**: the minimal set read to rebuild state).

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

## Terminals: tmux (the only session layer)

**tmux does all session work**, each session per its need:
- **`<tmux_base>_main`** — long/progress tools the operator watches live.
- the agent's own interactive sessions it drives via `send-keys`: reverse shells (`pwncat-cs`),
  `msfconsole`, handlers, and the **`<tmux_base>_dbg`** gdb session.
- **`<tmux_base>_oversee`** / **`<tmux_base>_auditor`** — the two reviewer sidecars.
tmux is zero-dependency and lives in the agent's shell env, so everything runs on it by default.
(The OpenVPN tunnel is a separate system daemon — `openvpn --daemon`, logged to `logs/openvpn.log`
— not a tmux session; it's shared infra and left up across hunts.)

> **herdr was removed** (it was decorative — it only placed the reviewer sidecars in sibling panes,
> which tmux sessions do just as well; its in-process agent coordination overlapped Claude Code's
> native sub-agents, so it was never used for that). One fewer moving part; tmux is the sole session
> layer. `rc2_launch_sidecar`/`rc2_stop_sidecar` are now tmux-only.

## Conventions

- **Doctrine drives behavior.** Prefer editing `doctrine/*.md` over hardcoding steps in the
  launcher. The launcher is plumbing; the doctrine is policy.
- **Evidence discipline.** The doctrine forbids recording unverified wins and forbids grinding
  (per-hypothesis evidence budgets → freeze + switch). Preserve this when editing — it is the
  main defense against the rabbit holes Insane boxes are built from.
- **Secrets.** `.env`, `runs/`, `*.ovpn`, keys, HARs are gitignored. Never put a password on a
  command line (it's hook-logged); root actions use `sudo -A` via the wired askpass.
- Temp/scratch for development goes in `tmp/`; per-run temp is `runs/<slug>/tmp` (`TMPDIR`).
- **Helper scripts** (`scripts/`): `watch.sh` (live run viewer: solver reasoning + every tool call/result);
  `agents.sh` (the complement — a read-only merged feed of ONLY the non-solver agents' responses: oversee +
  auditor + the Task sub-agents, from their logs; `-f` follow, `FULL=1`, `ONLY=`); `oversee.sh` (supervisor/
  critic → `supervisor.md`, auto-started by `hunt` in a `<tmux_base>_oversee` tmux session);
  `auditor.sh` (epistemic/conclusiveness auditor → `auditor.md`, auto-started by `hunt` in a
  `<tmux_base>_auditor` tmux session; `NO_AUDITOR=1`);
  `report.sh` + `analyze_run.sh` (retrospectives, auto-run by `hunt` on exit → `writeup.md`,
  `failure_analysis.md/.json`); `triage.sh` (per-run "thought vs execution" verdict over
  `failure_analysis.json` → `triage/<slug>.md` (tracked), **auto-run by `hunt` on exit** after `analyze_run.sh`;
  no-arg = cross-run rollup — the §4 investment signal); `gaps.sh` (read-only §5 digest:
  per-surface effort + log outcomes[conclusive vs inconclusive] + held assets → the stuck-time
  enumeration-gap + combination pass the orchestrator runs); `surface_label.sh` (**opt-in** Tier-2
  inferred-surface labeler, `RC2_SURFACE_TIER2=1`, prompt `SURFACE_LABEL.md` → `logs/surfaces_inferred.json`,
  folded into `gaps.sh`); `rag.sh` (cross-run memory over past runs); `machine.sh` (HTB
  API util: info/ip/spawn/active/stop/reset/submit by name, name→id auto, 15×3 min spawn wait);
  `burp.sh up|status|down` (optional Burp-over-MCP, opt-in before `./hunt`); `guard.sh` (set the
  guard's *live* level or `show` floor/live/effective — the guard's operator/oversee channel, §4a of
  the GUIDE); `install_tools.sh`
  (one-shot Kali toolset); `conv_fmt.py` (stream-json renderer); `auto_pr.sh` (optional dev-workflow
  Stop hook — branch→PR→merge, wired from a personal gitignored `.claude/settings.local.json`; not
  part of a hunt). `lib/tools_log.sh` holds the shared `logs/tools.jsonl` readers; `lib/guard_lib.sh`
  holds the dependency-free guard/JSON helpers shared by the standalone hook and the API.
- **Live state.** `hunt` runs background loops: `rc2_flag_watcher` (submits user/root flags via the HTB
  API through two channels — `flags.txt` and an enforced scan of logged `user.txt`/`root.txt` reads —
  with persistent dedup in `logs/.submitted`, incl. a per-value `kind:bad:<flag>` entry so a rejected
  flag is not re-hammered; `rc2_htb_owned_init` reads owned-status at launch → `logs/.flag_mode`
  `live` or `defer`-to-end), `rc2_status_writer` (rewrites `status.md` every 600s — flags, phase,
  hypotheses, the guard/ledger line, journal tail, recent tools, tmux, artifacts; also keeps a live
  "Confirmed path" block in `writeup.md`), `rc2_health_watcher` (probes the target every `HEALTH_INTERVAL`=30s
  on `HEALTH_PORTS`="22 80 443" → `target_health.md` UP/DOWN; while DOWN it re-checks the HTB API every
  `HEALTH_IP_RECHECK`=90s and, if the box respawned on a new IP, rewrites `target.env` + flags **TARGET MOVED**
  so the agent stops waiting on a dead IP — `NO_HEALTH=1` to disable), and — when a guard layer is on —
  `rc2_guard_watcher`. **All these loops exit on `logs/.stop`, so `hunt` clears a prior run's stale `.stop`
  at launch** (before starting them) — otherwise a resume would silently kill flag-submit/guard/health at
  t=0. The HTB spawn/IP wait is 15 tries × 180s = 45 min (`IP_WAIT_TRIES`/`IP_WAIT_INTERVAL`).
- **Resilient run loop & launch reset.** `rc2_run_loop` guards each `claude -p` attempt with a backgrounded
  `_rc2_attempt_guard`: a terminal **heartbeat** (`RC2_HEARTBEAT`=60s), a **cyber-spin kill** (`RC2_CYBER_SPIN`=10
  safeguard trips in one session → kill it; a fresh session re-trips the same content), and a **wedge kill**
  (`RC2_HANG_KILL`=600s with no output). A **usage/token-limit** stop is NOT treated as a crash: the loop
  detects it (`_rc2_log_has_usage_limit`, `RC2_USAGE_LIMIT_RE`) and **backs off `RC2_USAGE_BACKOFF`=1800s then
  resumes from disk without consuming a `MAX_RESTARTS` attempt** (bounded by `RC2_USAGE_MAX_WAITS`=12; the
  backoff wakes early on `logs/.stop`) — the real constraint on a long Insane hunt is the per-window token
  budget, so a limit stop is an expected, recoverable event, not a failure. At launch (before watchers) `hunt` also rolls `journal.md` over
  `RC2_JOURNAL_KEEP`=200 lines into `journal.archive.md` (`rc2_rotate_journal`, bounds re-hydration) and
  **re-applies `RC2_CEIL`/`RC2_WARN` to the resume-preserved `logs/accounting.json`** (the hook reads the
  ceiling from the file, so an operator override would otherwise be ignored on resume).
- **The guard (opt-in, off by default) covers BOTH failure modes.** It shares `ledger.json` (solver
  intent) + `logs/accounting.json` (harness counters — per-hypothesis **and per-surface** — solver-
  unwritable). *Against over-grinding:* the **hook** (per-call repeat/stall/frozen/ceiling warn-or-block
  + one-shot override), the **sameness watcher** (`rc2_guard_watcher` + `JUDGE.md`, out-of-band sonnet/
  haiku judge → persistent arbiter freeze), and the **oversee gate** (same-`FOCUS` consensus → raises the
  live level). *Against premature surrender on a wrongly-pruned surface* (the Nimbus "CodeBuild=mock →
  give up"): the **surrender gate** (`rc2_surrender_gate` + `SURRENDER.md`, opus) re-audits weak negatives
  + the privilege map on a clean-exit blocker and REOPENs a shallow higher-privilege dismissal, relaunching
  via a supervisor tick (bounded by `RC2_SURRENDER_MAX`); and — finer-grained, mid-run, not only at
  clean-exit — the **epistemic auditor** (`scripts/auditor.sh` + `AUDITOR.md`, opus, every `AUDITOR_INTERVAL`=420s),
  an independent reader of the RAW logs that catches the *second-order* surrender the Nimbus run showed — a
  vector correctly seen as LIVE but then refuted on **inconclusive** evidence (a test that FAULTed/timed-out/
  was-blocked and never reached the mechanism). It writes `auditor.md`; the hook **pushes** the solver to read
  it (warn → `exit 2` block after `AUDITOR_NUDGE_ESCALATE`=3 un-acked calls, self-clearing on a read of the file).
  Doctrine side (what the gates enforce): the solver
  **orients by the privilege delta** (a privilege map in `worldmodel.md`; `10`/`40`), **reasons from the
  artifact not the catalog** (`10`/`20` — a bespoke fork's delta is the surface), lets **conclusiveness (not
  effort) govern a freeze** — an inconclusive result forces a materially-different retry, and a vector
  inconclusive across `RC2_UNTESTABLE_MAX`=4 attempts is PARKED `untestable` (naming the missing capability),
  not refuted (`10`/`40`) — records **negatives with tested-depth + confidence** (`00`/`40`), and enumerates a
  new context openly before judging it dead.
  Enforcement is a **two-tier switch**: operator floor (`RC2_GUARD` env) ⊔ live (`logs/guard.mode`,
  secret-tagged via `logs/.guard_secret`), `effective=max`. Helpers in `lib/guard_lib.sh`, defaults in
  `lib/env.sh`, reference in GUIDE §4a.
- **Oversight.** `oversee.sh` runs an opus reviewer that writes `supervisor.md` only on drift; the
  solver follows a newer `SUPERVISOR_TICK` (doctrine `10-hunt-loop.md`). Its system prompt is
  `OVERSEER.md` (kept out of `doctrine/` so it never enters the solver's own prompt). With the guard
  enabled it also drives the **weighted gate** — only `RC2_GATE_N` consecutive same-`FOCUS`
  rabbit-hole verdicts raise the live guard level (via `guard.sh`, re-asserted each tick). A **second,
  orthogonal** sibling runs the same way — `auditor.sh` (prompt `AUDITOR.md`, also kept out of `doctrine/`),
  launched by `hunt` alongside oversee (`rc2_launch_auditor`/`rc2_stop_auditor`, a `<tmux_base>_auditor`
  tmux session; `NO_AUDITOR=1` disables). oversee judges **strategy** (rabbit-hole/
  priority, pull via `SUPERVISOR_TICK`); the auditor judges **evidence quality** (conclusiveness, push via
  `AUDITOR_TICK` + the hook). They are deliberately separate channels so "re-prioritize" never blurs with
  "your evidence is inconclusive".
- **Reversing** is export-first (`doctrine/60-reversing.md`): IDA → files under `reversing/`,
  grep locally, query IDA MCP only surgically; gdb runs in a `<tmux_base>_dbg` tmux session,
  launched with a plugin via the on-PATH wrappers `gdb-pwndbg` (default) / `gdb-gef` / `gdb-peda`
  (or `init-pwndbg`/`init-gef`/`init-peda` inside gdb). No plugin auto-loads — pick one per session.
