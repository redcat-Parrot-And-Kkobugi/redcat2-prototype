# redcat2 — Full Guide

An autonomous offensive-research agent for Hack The Box–style machines (Easy → Insane).
The engine is Claude Code headless (`claude -p`); the intelligence is a compact **doctrine**
that makes the agent reason like a researcher — observe → hypothesize → research → experiment
→ verify → reflect — rather than run a playbook. **Authorized labs only.** `./hunt` executes
real commands against the target with `--dangerously-skip-permissions`.

> This guide is how to **operate** redcat2. For the design rationale — the whole pipeline, why it is
> built this way, the goals, and the guard's failure-mode model, with diagrams — see the
> **[Developer Guide](DEVELOPER.md)**.

- [1. Quick start](#1-quick-start)
- [2. One-time setup](#2-one-time-setup)
- [3. The `hunt` command + env toggles](#3-the-hunt-command--env-toggles)
- [4. How it thinks (the Hunt Loop + doctrine)](#4-how-it-thinks)
- [5. Sub-agents](#5-sub-agents)
- [6. The run directory & living memory](#6-the-run-directory--living-memory)
- [7. Every script](#7-every-script)
- [8. tmux](#8-tmux)
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
./hunt Blizzard                      # HTB name → resolve/spawn → run (Opus 4.8 orchestrator)
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
- **Burp** (optional) — `scripts/burp.sh up` before `./hunt` for `mcp__burp__*`.

---

## 3. The `hunt` command

```
./hunt [--fresh] <machine_name|ip> [orchestrator_model] [extra notes]
```

- **`<machine_name|ip>`** — an HTB name (resolved + spawned via the API; needs a token) or a raw
  IP (IP-only mode: no spawn/submit).
- **`[orchestrator_model]`** — the orchestrator model; default `claude-opus-4-8` (Opus 4.8). Sub-agents pick their own.
- **`[extra notes]`** — free-text hint appended to the launch prompt.
- **`--fresh`** — archive any existing run for this target and start clean.

### Environment toggles

| var | default | effect |
|---|---|---|
| `MAX_RESTARTS` | 20 | auto-relaunch budget on crash/overflow |
| `NO_RESTART` | 0 | `1` = run the agent once, no auto-relaunch |
| `NO_OVERSEE` | 0 | `1` = don't start the supervisor |
| `NO_AUDITOR` | 0 | `1` = don't start the epistemic auditor (conclusiveness gate; see [§4a](#4a-the-guard--anti-rabbit-hole-enforcement)) |
| `NO_STOP` | 0 | `1` = on solve, don't terminate the HTB machine (keep the box up) |
| `VPN_AUTOFIX` | 0 | `1` = if pre-flight finds the wrong VPN server (HTB_OVPN mismatch, or target routes but is host-unreachable), auto-reconnect to `HTB_OVPN` |
| `CYBER_MAX_RETRIES` | 10 | relaunches allowed when the agent is cyber-safeguard-flagged before the loop stops (content flags re-trip, so this caps churn) |
| `RC2_USAGE_BACKOFF` | 1800 | on a usage/token-limit stop (not a crash), seconds to back off before resuming from disk; wakes early on `logs/.stop` |
| `RC2_USAGE_MAX_WAITS` | 12 | max usage-limit backoffs before the loop stops (does **not** consume `MAX_RESTARTS`) |
| `RC2_USAGE_LIMIT_RE` | (built-in) | override the regex that recognizes a usage/rate/overload-limit stop in the session log |
| `CYBER_FALLBACK_MODEL` | — | on a cyber-safeguard flag, switch the orchestrator to this (less-restricted) model for the next session |
| `OVERSEE_FALLBACK_MODEL` | — | model the supervisor retries a cyber-flagged review with (one retry); `scripts/oversee.sh` only |
| `OVERSEE_INTERVAL` | 600 | supervisor review cadence (s) |
| `AUDITOR_INTERVAL` | 420 | epistemic auditor review cadence (s) |
| `AUDITOR_MODEL` | `claude-opus-4-8` | model for the auditor's conclusiveness call (opus, capped at 4.8) |
| `AUDITOR_FALLBACK_MODEL` | — | model the auditor retries a cyber-flagged review with (one retry); `scripts/auditor.sh` only |
| `AUDITOR_NUDGE_ESCALATE` | 3 | hook pushes (warn) this many times for a new `auditor.md` finding, then hard-blocks (exit 2) until the solver reads it |
| `RC2_UNTESTABLE_MAX` | 4 | materially-different inconclusive attempts on one vector before it is parked `untestable` (not refuted) |
| `STATUS_INTERVAL` | 600 | `status.md` snapshot cadence (s) |
| `FLAG_INTERVAL` | 300 | flag auto-submit watcher poll cadence (s) |
| `IP_WAIT_TRIES` | 15 | spawn/IP poll attempts |
| `IP_WAIT_INTERVAL` | 180 | seconds between IP polls (15×180s = 45 min) |
| `HAR_SRC` | Windows DevTools folder | where to import the newest HAR from |
| `FRESH` | — | same as `--fresh` |

**Model pinning (`rc2_pin_model`, `lib/env.sh`) — caps opus at 4.8:**

| var | default | effect |
|---|---|---|
| `RC2_PIN_MODEL` | `claude-opus-4-8` | the id a capped opus is pinned **to**. A bare `opus` alias or any `claude-opus-5+` id → this; sonnet/haiku and `claude-opus-4-*` pass through unchanged (the cyber safeguard trips hardest on Claude-5 opus) |
| `RC2_NO_PIN` | `0` | `1` = disable the opus cap entirely (use the model exactly as requested) |

**Prompt-cache / relaunch efficiency (`lib/env.sh`; caching is server-side, no local cache):**

| var | default | effect |
|---|---|---|
| `CLAUDE_CODE_PROMPT_CACHE_TTL` | `1h` | orchestrator cache TTL — a relaunch within the window reuses the byte-stable doctrine prefix (OAuth-only; `ANTHROPIC_API_KEY` is unset to keep 1h eligibility) |
| `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL` | `1h` | same, for Task sub-agents reusing their stable prefix |
| `DISABLE_AUTOUPDATER` | `1` | an auto-update between relaunches would cost one cold turn |

**Attempt watchdog, journal rollover, target-health (all per-run, `lib/run.sh`):**

| var | default | effect |
|---|---|---|
| `RC2_HEARTBEAT` | `60` | emit a `[hunt] attempt N live …` heartbeat to the terminal every N s so a long attempt doesn't look paused (`0` = off) |
| `RC2_CYBER_SPIN` | `10` | kill an attempt once it has tripped the cyber safeguard this many times in one session — a fresh session re-trips the same content (`0` = off) |
| `RC2_HANG_KILL` | `600` | kill an attempt that has emitted nothing for this many s (wedged → relaunch) (`0` = off) |
| `RC2_GUARD_TICK` | `15` | watchdog poll cadence (s) |
| `RC2_JOURNAL_KEEP` | `200` | at launch, roll `journal.md` older than the last N lines into `journal.archive.md` (bounds resume re-hydration; `0` = off) |
| `NO_HEALTH` | `0` | `1` = don't start the target-health watcher |
| `HEALTH_INTERVAL` | `30` | target liveness probe cadence (s) → `target_health.md` |
| `HEALTH_PORTS` | `22 80 443` | ports the health watcher probes for UP/DOWN |
| `HEALTH_IP_RECHECK` | `90` | while the box is DOWN, re-query the HTB API this often; on a new respawn IP, rewrite `target.env` + flag **TARGET MOVED** |

**Guard / anti-rabbit-hole (see [§4a](#4a-the-guard--anti-rabbit-hole-enforcement); all off by default):**

| var | default | effect |
|---|---|---|
| `RC2_GUARD` | `off` | operator **floor** = minimum enforcement that the solver/supervisor can never go below: `off` \| `warn` (nudge only) \| `block` (refuse the call). `!=off` also turns the sameness watcher + oversee gate on |
| `RC2_GATE` | `0` | `1` = let **oversee** raise the *live* guard level on rabbit-hole consensus (floor stays whatever `RC2_GUARD` is). One switch for full automation; also starts the watcher |
| `RC2_GUARD_WATCH` | `0` | `1` = start the sameness-judge watcher without setting a floor (judge+freeze only) |
| `NO_GUARD_WATCH` | `0` | `1` = force the watcher off even if a floor/gate is set |
| `RC2_GATE_MODE` | `block` | the live mode oversee escalates to on consensus (set `warn` for observe-only) |
| `RC2_GATE_N` | `2` | consecutive same-`FOCUS` rabbit-hole reviews before oversee escalates |
| `RC2_REPEAT_FREEZE` | `4` | identical-action repeats on one hypothesis before the hook warns/blocks |
| `RC2_STALL` | `12` | experiments on one hypothesis with no new evidence before the judge is asked |
| `RC2_CEIL` / `RC2_WARN` | `800` / `450` | global experiment hard-stop / warn line (calibration: solved runs ran ~186–416 calls) |
| `RC2_BUDGET_DEFAULT` | `8` | per-hypothesis attempt budget seeded into `ledger.json` |
| `GUARD_JUDGE_MODEL` | `sonnet` | model for the out-of-band sameness judge (`haiku` = cheaper/coarser) |
| `GUARD_WATCH_INTERVAL` | `180` | sameness-judge watcher cadence (s) |
| `RC2_SURRENDER_MAX` | `2` | max times the surrender gate may re-open a blocker and relaunch (`0` disables) |
| `RC2_SURRENDER_MODEL` | `claude-opus-4-8` | model for the independent surrender-gate re-audit (an opus reviewer, capped at 4.8 — never 5.x) |
| `NO_SURRENDER` | `0` | `1` = never run the surrender gate (accept a clean-exit blocker as-is) |

All guard defaults live in **one place** — `lib/env.sh` — and are overridable via `.env` or the launch env.
The surrender gate runs whenever the guard is enabled (`RC2_GUARD!=off`, `RC2_GATE=1`, or `RC2_GUARD_WATCH=1`).

### Launch sequence (what `./hunt` does)
load `.env` (incl. guard defaults) → refresh HTB token from newest HAR if stale → resolve/spawn the box
(wait up to 15×3 min) → VPN pre-flight (`openvpn --daemon` if `HTB_OVPN` set) → scaffold `runs/<slug>/`
(seed the 3 living files + `ledger.json` + `logs/accounting.json` + the guard secret) → read HTB
owned-flag status (sets live/defer flag-submit mode) → start the flag auto-submitter, the `status.md`
writer, the supervisor + the epistemic auditor (each a tmux session), and — when any guard
layer is enabled — the sameness-judge
watcher → build the system prompt from `doctrine/*.md` → run `claude -p` in the resilient loop → on exit
write `writeup.md` + `failure_analysis.*` and a final `status.md`. **On a solve** (both flags) it also
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

## 4a. The guard — anti-rabbit-hole enforcement

Hard/Insane boxes fail two opposite ways, and the guard covers both:
1. **Grinding a disproven hypothesis** — e.g. the Nimbus run burned 832 tool calls re-trying one
   container-escape across 6 sessions while solved boxes finished in ~186–416.
2. **Premature surrender on a wrongly-pruned surface** — the same run dismissed **CodeBuild as "a mock"
   from one 0.5 s build**, recorded that shallow negative as fact, never re-opened it, and declared a
   confident (wrong) blocker — when `privilegedMode=true` there was a root container with the host's
   block devices (the actual root path).

Doctrine forbids both, but prose alone did not stop them. The guard adds **mechanical enforcement**,
opt-in and off by default, sharing state and bounded below by the operator.

**Layers**
- **Hook** (`lib/hook_log.sh`, per tool call, mechanical) — counts experiments per hypothesis **and per
  surface** in `logs/accounting.json`; warns or blocks on a literal action repeated `RC2_REPEAT_FREEZE`×,
  a `frozen` hypothesis, or the global `RC2_CEIL`. The per-surface tally (codebuild:1 vs ecs:203…) is how
  a lopsided, under-explored surface gets flagged. Cheap and fast; **not** the semantic judge.
- **Sameness watcher** (`rc2_guard_watcher` + `JUDGE.md`, out-of-band, model) — when a hypothesis stalls
  (`RC2_STALL` experiments, no new evidence) an **independent sonnet/haiku judge** rules *SAME* (rabbit
  hole → persistent **arbiter freeze**, solver can't clear) or *VARYING* (let it run). Catches
  textually-varied drilling the hook's literal fingerprint cannot. [failure mode 1] It also emits a
  **`contradiction` signal** — when recent actions *presuppose* a fact the agent recorded absent/refuted
  (e.g. chasing a `docker.sock` it already found absent at high confidence) it writes a supervisor tick
  telling the solver to re-test that negative or open-enumerate. [failure mode 3: "fix the want, then solve"]
- **Oversee gate** (`scripts/oversee.sh`, opus, trajectory) — only after `RC2_GATE_N` consecutive
  rabbit-hole reviews about the **same `FOCUS`** does the supervisor raise the live guard level
  (re-asserted each tick; released on any on-track review). [failure mode 1]
- **Surrender gate** (`rc2_surrender_gate` + `SURRENDER.md`, opus, the mirror image) — when the solver
  **clean-exits as a blocker**, an independent reviewer re-audits its privilege map + weakest negatives +
  the per-surface tally and either ACCEPTs the surrender or names a concrete **REOPEN** (component +
  elevation primitive), which relaunches the solver via a supervisor tick. Bounded by `RC2_SURRENDER_MAX`.
  This is what catches the Nimbus "CodeBuild=mock → give up". [failure mode 2]
- **Epistemic auditor** (`scripts/auditor.sh` + `AUDITOR.md`, opus, out-of-band, every `AUDITOR_INTERVAL`=420s)
  — the **mid-run, finer-grained** counterpart to the surrender gate (which only fires at clean-exit). It
  reads the raw logs and judges one thing: is a negative the solver leans on **conclusive** (the mechanism
  ran and answered) or **inconclusive** (the test FAULTed / timed out / was blocked and never reached the
  mechanism)? The Nimbus run is the exact case it exists for: CodeBuild was correctly seen as LIVE, then
  refuted at high confidence on FAULT-before-BUILD results — a test that never ran. On a mismatch it writes
  `auditor.md`; the **hook pushes** the solver to read it (warn `AUDITOR_NUDGE_ESCALATE`× then exit-2 block,
  self-clearing on a read). A vector that returns only inconclusive results across `RC2_UNTESTABLE_MAX`=4
  materially-different attempts is parked **`untestable`** (naming the missing capability), not refuted.
  Separate channel (`AUDITOR_TICK`) from oversee's `SUPERVISOR_TICK` so "re-prioritize" never blurs with
  "your evidence is inconclusive". [failure mode 2, mid-run]

**Orientation & evidence discipline (the doctrine side the guard enforces)** — the solver is told to
**orient by the privilege delta**: keep a *privilege map* in `worldmodel.md` (who/what runs above you,
and does your input reach it) and hunt elevation across *all* domains, not just the one you're in; to
record a **negative** only with how-deeply-tested + confidence (a shallow "it's a mock" is a hypothesis,
not a fact); and, on entering any new execution context, to **enumerate it openly** (devices, caps,
mounts, privilege) before judging it dead. It is also told to let **conclusiveness, not effort, govern a
freeze** — an inconclusive result (a test that never reached the mechanism) forces a materially-different
retry, and a vector inconclusive across `RC2_UNTESTABLE_MAX` attempts is parked `untestable`, not refuted —
and to **reason from the artifact, not the catalog**: on a bespoke fork the delta from the stock product is
the surface (the surest-cached image is the one the box already runs). The surrender gate and the epistemic
auditor are the hard backstops when these slip.

**Two-tier switch (who controls enforcement)**
- **floor** = `RC2_GUARD` (operator env, set at launch) — the minimum that is always in effect; neither
  the solver nor oversee can go below it.
- **live** = `logs/guard.mode` (written by oversee/operator via `scripts/guard.sh`, authenticated by a
  secret tag in `logs/.guard_secret` the solver may not read) — the dynamic level.
- **effective = the stronger of the two.** So the operator guarantees a minimum, automation can only
  tighten it, and the solver can never weaken its own guard. `scripts/guard.sh <run> show` prints all three.

**State (intent vs accounting)** — `ledger.json` is the solver's *intent* (current hypothesis, its own
freezes, a one-shot `override`); `logs/accounting.json` is the harness's *counters* and the arbiter
freezes, which the solver must never write. Keeping them separate means a bad hand-edit can't corrupt
the counters enforcement rests on. A guard block always names the reason, the ledger snapshot, the exact
command, and the three ways out: **vary materially**, **freeze + switch**, or spend a one-shot `override`.
The solver also records **load-bearing negatives** in `ledger.negatives` (`{fact, confidence, tested}`);
these are what the surrender gate re-opens and the contradiction check reads, and a shallow negative is
explicitly a re-open candidate, not a wall. Finally, a run counts as **SOLVED only when both flags are
*accepted* by the lab** (not merely written to `flags.txt`) — so a captured-but-rejected/stale flag never
terminates the machine.

**Design deep-dive:** the full rationale — the failure modes, the authority model, the state split, the
replay/negatives/contradiction mechanisms, with diagrams — is in [`DEVELOPER.md`](DEVELOPER.md) §4.

**Turning it on** (see the toggles table above):
```bash
./hunt Box                          # default: guard OFF (no behaviour change)
RC2_GUARD=warn ./hunt Box           # floor=warn: nudges only; watcher + oversee gate also on
RC2_GATE=1 ./hunt Box               # full auto: floor off, oversee escalates to block on consensus
RC2_GUARD=block ./hunt Box          # hard enforcement from the start
scripts/guard.sh Box show           # floor / live / effective right now
```

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
- `ledger.json` — the machine-readable **mirror** of the board (current hypothesis, per-hypothesis
  status/budget/freeze, confirmed path, one-shot override). The solver keeps it in sync with
  `hypotheses.md`; the guard (§4a) reads it. Its **`confirmed_path`** entries record each proven step's
  `how` (method) + `yields` (success signal), so on resume the solver **re-walks** the proven chain with
  its own reasoning+tools — adapting to the respawned instance's fresh creds/IDs/flags — instead of
  re-deriving it from the journal. See `doctrine/40-memory-and-state.md` → Resume.

Raw evidence and auto files alongside:

```
target.env   recon/ enum/ loot/ exploit/ reversing/ research/ tools/ bin/ notes/ cache/
flags.txt    user=<hex> / root=<hex>  (recorded instantly; submitted per §11)
journal.archive.md   entries rolled out of journal.md (RC2_JOURNAL_KEEP); history, NOT read on resume
cache/       run-local scratch only — NOT Claude's config/cache (relocating CLAUDE_CONFIG_DIR would break user MCP)
status.md    auto snapshot every ~10 min (read-only to the agent); shows guard floor/live/effective
target_health.md   auto UP/DOWN/MOVED box signal (rc2_health_watcher); read it on mass connection failures
writeup.md   live "Confirmed path" block (updated as steps confirm) + metrics (report.sh, on exit)
failure_analysis.md/.json   why the run went as it did (analyze_run.sh, on exit)
supervisor.md   reviewer verdicts, when oversee is running
auditor.md      conclusiveness-audit findings, when auditor is running (hook pushes the solver to read it)
logs/        conv.jsonl (full conversation), tools.jsonl + raw/ (every tool call),
             accounting.json (guard counters — harness-owned; §4a), guard.log (guard actions),
             guard.mode + .guard_secret (live-mode channel), .flag_mode (live|defer),
             .submitted (flag dedup), system_prompt.txt, meta.env, phases.log, flag_submit.log, session_*.log
.claude/     settings.json (logging + guard hook) + agents → ../../.claude/agents
```

Resume reads a fixed **resume kernel**, in order: top of `worldmodel.md` → ranked `hypotheses.md` →
tail of `journal.md` → `ledger.json`'s `confirmed_path` → `flags.txt` — and nothing else to rebuild
state (not `status.md`, `journal.archive.md`, or raw `logs/`/`enum/`, which only re-pay context the
kernel already gives). `ledger.json` / `logs/accounting.json` persist the guard state across the
restart, so a frozen hypothesis stays frozen for the fresh instance.

---

## 7. Every script

Run from the repo root. Most take a run slug/name/IP, defaulting to the newest run.

| script | usage | what it does |
|---|---|---|
| `hunt` | `./hunt [--fresh] <name|ip> [model] [notes]` | the launcher (§3) |
| `scripts/watch.sh` | `scripts/watch.sh [name]` | live feed: agent reasoning + every tool call/result. `FULL=1` whole outputs, `NOCONV=1` tool-feed only, `MAX=<n>` lines |
| `scripts/agents.sh` | `scripts/agents.sh [name]` | the complement to watch: ONLY the non-solver agents' responses (oversee + auditor + Task sub-agents) merged chronologically, read-only. `-f` follow, `-n N`/`TAIL` last N, `FULL=1` whole sub-agent results, `ONLY=oversee\|auditor\|agents` |
| `scripts/oversee.sh` | `scripts/oversee.sh <slug> ["directive"]` | supervisor/critic loop → `supervisor.md` on drift. `OVERSEE_INTERVAL`, `OVERSEE_MODEL`, `ONESHOT=1`. Auto-started by `hunt` |
| `scripts/auditor.sh` | `scripts/auditor.sh <slug>` | epistemic/conclusiveness auditor loop → `auditor.md` on a misclassified (inconclusive-as-refuted) negative; the hook pushes the solver to read it. `AUDITOR_INTERVAL`, `AUDITOR_MODEL`, `ONESHOT=1`. Auto-started by `hunt` |
| `scripts/report.sh` | `scripts/report.sh <rundir>` | metrics → `writeup.md` (wall time, tool/Task counts, per-phase). Auto on exit |
| `scripts/analyze_run.sh` | `scripts/analyze_run.sh [rundir|name]` | failure classifier → `failure_analysis.md/.json`. Auto on exit |
| `scripts/rag.sh` | `scripts/rag.sh [-p] <query>` | cross-run memory: grep your own past runs. `-p` also searches `reference/` + PayloadsAllTheThings/GTFOBins. `SCOPE=runs/<slug>` to narrow |
| `scripts/machine.sh` | `scripts/machine.sh <cmd> <name|id> [flag]` | HTB API util: `info` / `ip` / `spawn` / `active` / `stop` / `reset` / `submit`. Names resolve to ids |
| `scripts/guard.sh` | `scripts/guard.sh <name> <off\|warn\|block\|show> ["reason"]` | set the **live** guard level (oversee/operator channel; §4a) or `show` floor/live/effective. Tagged so the solver can't forge it |
| `scripts/burp.sh` | `scripts/burp.sh up|status|down|restart` | optional Burp headless over MCP; registers `mcp__burp__*`. Needs `BURP_MCP_TOKEN` |
| `scripts/install_tools.sh` | `scripts/install_tools.sh [core|max|--check]` | install the Kali toolset |
| `scripts/auto_pr.sh` | (Stop hook) | on a file-changing turn: branch → commit → push → PR → merge to `main` via `gh`. No-op on a clean tree. `AUTO_PR_DISABLE=1`, `AUTO_PR_MERGE`, `AUTO_PR_MODEL`. Dev-workflow only — nothing to do with a hunt. See [TOOLS.md](TOOLS.md) |
| `scripts/conv_fmt.py` | (internal) | renders `claude -p` stream-json into a readable transcript |
| `scripts/lib/htb_api.sh` | `scripts/lib/htb_api.sh {profile|active|spawn|terminate|reset|own}` | raw HTB API client (sourceable or CLI) |
| `tools/env-setting/set_token_from_har.sh` | `… <file.har>` | extract + verify the labs token from a HAR → `.env` |
| `tools/env-setting/check_token.sh` | `…` | validate the current token/env against the live API |

Library (sourced, not run directly): `lib/bootstrap.sh` (loader; chain: common → tools_log → env →
htb → run), `lib/guard_lib.sh` (dependency-free guard/JSON helpers — `rc2_json_update`,
`rc2_guard_tag`, `rc2_guard_effective`, `rc2_is_frozen`, `rc2_guard_core_on`; shared by the standalone
hook and the API), `lib/common.sh` (colors, run-dir resolve, UTC time, flag + target.env helpers,
`rc2_write_supervisor`; sources guard_lib),
`lib/tools_log.sh` (shared `logs/tools.jsonl` readers, `rc2_tl_*`), `lib/env.sh` (.env, SecLists,
guard-default knobs), `lib/htb.sh` (token/resolve/spawn/VPN pre-flight/flag watcher + owned-status
init), `lib/run.sh` (scaffold, prompts, resilient run loop + **surrender gate** on clean-exit, status
writer, sameness-judge watcher, `rc2_claude_oneshot` out-of-band model runner, oversee launch),
`lib/hook_log.sh` (per-tool-call logging hook + anti-DoS repeat guard + the P1 accounting/guard).

**Full per-tool usage** — every flag, env knob, and example for the above — is in
[`docs/TOOLS.md`](TOOLS.md). This table is the index; that file is the reference.

---

## 8. tmux

tmux is the only session layer (zero-dependency, always present) — all in-box sessions: `<tmux_base>_main`
(long/progress tools you watch), the agent's own interactive sessions it drives with `send-keys` (reverse
shells via `pwncat-cs`, `msfconsole`, handlers, the `<tmux_base>_dbg` gdb session), and the two reviewer
sidecars `<tmux_base>_oversee` / `<tmux_base>_auditor`. `tmux_base` is `rc2_<slug>`.

> **herdr was removed.** It was an optional outer runtime that only placed the reviewer sidecars in
> sibling panes — something tmux sessions do just as well — and its in-process agent coordination
> overlapped Claude Code's native sub-agents, so it was never used for that. Dropping it removes a moving
> part; `rc2_launch_sidecar`/`rc2_stop_sidecar` are now tmux-only.
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
  a written blocker) is respected and not relaunched. `NO_RESTART=1` runs once. Each relaunch prints
  the target line and, if the box was respawned to a new IP, refreshes it from the HTB API (updating
  `target.env`). Between relaunches, `rc2_health_watcher` also refreshes the IP **mid-run** (every
  `HEALTH_IP_RECHECK` while the box is down), so a respawn during a long "waiting for the box" session
  no longer strands the agent on a dead IP.
- **Per-launch reset:** every `./hunt` clears a prior run's stale `logs/.stop` before starting the
  background loops (otherwise a resume would kill flag-submit/guard/health at t=0), rolls `journal.md`
  over `RC2_JOURNAL_KEEP` lines into `journal.archive.md`, and re-applies `RC2_CEIL`/`RC2_WARN` to the
  resume-preserved `logs/accounting.json` so an operator ceiling override takes effect on resume.
- **Fresh:** `./hunt --fresh <target>` archives the old run to `runs/<slug>.bak.<epoch>` and starts
  clean.

---

## 11. Observability

- **Live feed:** `scripts/watch.sh` (second terminal) — reasoning + every command and result.
  By default it shows activity **from the moment you attach** (not the whole backlog); `REPLAY=1`
  replays the run's full history first. Ctrl-C stops it cleanly (its conv renderer runs in its own
  process group). The main `./hunt` terminal stays quiet: it shows only launch chrome (token/htb/vpn/
  oversee/banner) and the exit summary (report/analyze/stopped). The agent conversation goes to
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
| target routes but unreachable (gateway says host-unreachable) | wrong VPN server/region — the machine lives on another server; connect the `.ovpn` where it's spawned (your HTB panel), or `VPN_AUTOFIX=1 ./hunt …` with `HTB_OVPN` set. Pre-flight now warns on this |
| reviewer/agent "cyber-flagged" (safeguards) | a fresh session won't clear a content-based flag; set a `CYBER_FALLBACK_MODEL` / `OVERSEE_FALLBACK_MODEL` (less-restricted model) or apply to the Cyber Verification Program. oversee no longer writes a `supervisor.md` tick on a failed review; hunt caps cyber relaunches at `CYBER_MAX_RETRIES` |
| agent keeps restarting | it's crashing/overflowing; check `logs/session_*.log`; `NO_RESTART=1` to stop the loop. (A usage/token-limit stop is handled separately — it backs off and resumes without burning restarts; see `RC2_USAGE_*`.) |
| agent "spinning" / waiting on a dead box | the box likely reset/respawned to a new IP. `rc2_health_watcher` writes `target_health.md` (UP/DOWN/MOVED) and, on a new respawn IP, rewrites `target.env` + flags **TARGET MOVED**. Confirm the live IP with `scripts/machine.sh ip <name>`; a relaunch re-resolves it. (If the health watcher didn't run, check `logs/.stop` wasn't stale — `hunt` now clears it at launch.) |
| attempt hangs / looks paused | a long attempt is silent in the main terminal by design; the watchdog emits a `[hunt] attempt N live …` heartbeat and kills a cyber-spin (`RC2_CYBER_SPIN`) or no-output wedge (`RC2_HANG_KILL`). Watch `scripts/watch.sh` for the real activity |
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
  CLAUDE.md README.md OVERSEER.md JUDGE.md SURRENDER.md .env.example .gitignore
  docs/GUIDE.md docs/TOOLS.md docs/DEVELOPER.md   operate · per-tool · design rationale
  doctrine/00..60           the brain (system prompt)
  .claude/agents/           researcher recon-analyst exploit-dev verifier reverser
  .claude/settings.local.json   personal auto-PR Stop hook       (gitignored)
  lib/                      bootstrap guard_lib common tools_log env htb run hook_log
  reference/surface-signals.md  observation→environment→direction (consulted when ports are thin)
  scripts/                  watch oversee guard report analyze_run rag machine burp install_tools conv_fmt auto_pr
  scripts/lib/htb_api.sh    HTB API client
  tools/env-setting/        set_token_from_har check_token
  har/                      drop HARs here            (gitignored)
  runs/<slug>/              per-box workspace + memory (gitignored)
```

`OVERSEER.md` = supervisor system prompt; `JUDGE.md` = the sameness-judge prompt; `SURRENDER.md` = the
surrender-gate re-audit prompt (all §4a). Kept out of `doctrine/` so they never enter the solver's own prompt.
