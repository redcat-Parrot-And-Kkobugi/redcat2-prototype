# redcat2

An **autonomous offensive-research agent** for Hack The Box–style machines of **every
difficulty, Easy through Insane** (its edge shows most on the hard ones). The engine is
Claude Code itself; the intelligence is a compact *doctrine* that makes the agent reason
like a researcher instead of running a checklist, scaling its effort to what the box demands.

> 한국어 요약: redcat2는 정해진 플레이북을 따라가던 redcat1(기법 조합형)과 달리,
> **관찰 → 가설 → 조사 → 실험 → 검증 → 방향 재조정** 루프를 스스로 돌리는 자율 연구형
> 에이전트입니다. 모르는 건 인터넷(구글 도킹 포함)에서 직접 조사하고, 필요한 도구는
> 스스로 설치·제작하며, 여러 모델(해이쿠/소네트/오퍼스)을 서브에이전트로 부려 user.txt +
> root.txt 까지 도달하는 것을 목표로 합니다.

**Authorized labs only.** `./hunt` runs real commands against the target with
`--dangerously-skip-permissions`. Point it only at machines you are permitted to test.

**Full guide:** [`docs/GUIDE.md`](docs/GUIDE.md) — setup, every command and flag, every script,
tmux/herdr, reversing, resume, observability, security, and troubleshooting.
**Developer guide:** [`docs/DEVELOPER.md`](docs/DEVELOPER.md) — the whole pipeline, why it is built
this way, the guard's failure-mode model, the data model, and the invariants, with ASCII diagrams.

## Quick start

```bash
cp .env.example .env            # fill CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)
./hunt Blizzard                 # HTB name -> API resolves/spawns; Opus 4.8 orchestrator (default)
./hunt 10.10.11.42 opus "notes" # raw IP (IP-only mode if no HTB token); 2nd arg overrides the model
```

**HTB token is hands-off.** Save a devtools HAR from a logged-in `app.hackthebox.com`
(Network tab → Save all as HAR) into your capture folder `HAR_SRC` (default
`/mnt/c/Users/Godjs/Desktop/tmp/htb-api-har`). When the labs token is missing or expired,
`./hunt` copies the newest HAR from there into `har/`, extracts and verifies the `aud:6`
bearer, writes it to `.env`, then resolves the machine (OS/difficulty/IP), spawns it if
needed, and auto-submits captured flags via the API. The whole HAR → token → spawn → submit
pipeline is bundled and automatic.

**The supervisor runs alongside by default.** `./hunt` starts `oversee.sh` so the critic watches
and writes `supervisor.md` without a second terminal — in a **herdr sibling pane** when you run
`./hunt` inside herdr, otherwise a `<tmux_base>_oversee` tmux session. `NO_OVERSEE=1 ./hunt …`
disables it; `OVERSEE_INTERVAL=300` tunes the cadence. A second sibling, `auditor.sh`, runs the
same way (an `<tmux_base>_auditor` session / herdr pane) and audits **evidence quality** rather than
strategy — it catches a vector abandoned on an inconclusive result and pushes the solver to re-open
it. `NO_AUDITOR=1` disables it; `AUDITOR_INTERVAL=300` tunes the cadence.

Re-run the same target to **resume** — state lives on disk, not in the transcript. Add
`--fresh` to archive the old run and start clean. A crash or context overflow mid-hunt
**auto-relaunches** and resumes from disk (budget `MAX_RESTARTS`, default 20; `NO_RESTART=1`
to run once). If the box resets/respawns to a new IP mid-hunt, a background health watcher
rewrites `target.env` and flags **TARGET MOVED** so the agent re-points instead of stalling on
a dead IP. Relaunch cost is cut by a 1h server-side prompt-cache TTL on the stable doctrine prefix.

**Watch it live** (second terminal) — the agent's reasoning plus every command and result:

```bash
scripts/watch.sh                 # newest run — LIVE from now (REPLAY=1 to replay full history)
```

(`FULL=1` whole outputs, `NOCONV=1` tool-feed only. Ctrl-C stops it cleanly.)

**VPN** is handled for you: if the target isn't already routed, `./hunt` brings the HTB tunnel
up as an `openvpn --daemon` (logged to the run dir) and leaves it up across hunts. Pre-flight also
**checks you're on the right server** — it warns if a running VPN config differs from `HTB_OVPN`, or
if the target routes but the gateway says host-unreachable (you're on the wrong VPN server/region);
`VPN_AUTOFIX=1` reconnects to `HTB_OVPN` automatically.

**Optional Burp** for web-heavy boxes — bring it up first and `./hunt` inherits `mcp__burp__*`:

```bash
scripts/burp.sh up               # launch Burp headless + register its MCP (needs BURP_MCP_TOKEN)
```

## How it thinks — the Hunt Loop

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

Every pass advances one hypothesis with the best (confidence × impact ÷ cost), researches
anything it doesn't know cold *before* acting, runs the minimal experiment, verifies the
result independently, then updates a ranked attack board. Hypotheses carry **evidence
budgets**: no movement after the budget → freeze it, write why, switch. That discipline is
the main defense against the rabbit holes Insane boxes are designed around.

Full methodology: [`doctrine/`](doctrine/). Start at
[`00-prime-directive.md`](doctrine/00-prime-directive.md).

## Architecture

| Layer | Where | Role |
|---|---|---|
| **Brain** | `doctrine/*.md` | The whole methodology, concatenated into the system prompt. Prose, not code. Edit this to change how the agent thinks. |
| **Team** | `.claude/agents/*.md` | Multi-model sub-agents: `researcher` (sonnet), `recon-analyst` (haiku), `exploit-dev`/`verifier`/`reverser` (opus, pinned `claude-opus-4-8`). One file each; add a specialist by adding a file. Opus is capped at 4.8 everywhere (`rc2_pin_model`); only sonnet/haiku run Claude-5. |
| **Memory** | `runs/<slug>/` | Three living files — `worldmodel.md` (verified facts), `hypotheses.md` (attack board), `journal.md` (decision trail) — plus `ledger.json`, raw evidence dirs, and auto read-only companions `status.md` / `target_health.md`. Survives context resets (resume reads a fixed kernel). |
| **Plumbing** | `hunt`, `lib/`, `scripts/`, `tools/` | Launcher, env/HTB/VPN bootstrap, bundled HTB API client, HAR token extractor, tool-logging hook, flag auto-submit. |

## Layout

```
redcat2/
  hunt                       launcher: ./hunt [--fresh] <name|ip> [model] [notes]
  CLAUDE.md  README.md  OVERSEER.md  .env.example  .gitignore
  doctrine/                  the brain — concatenated (00..60) into the system prompt
    00-prime-directive.md      identity, hard rules, done-condition
    10-hunt-loop.md            ORIENT->RESEARCH->EXPERIMENT->OBSERVE->VERIFY->REFLECT + budgets
    20-research-and-dorking.md live-internet research + Google dorking + exploit vetting
    30-interactive-and-tools.md tmux sessions, install/build tools on the fly
    40-memory-and-state.md     the three living files + run-dir layout
    50-subagents.md            the team + when to delegate
    60-reversing.md            IDA export-first + gdb-in-tmux
  .claude/agents/            multi-model sub-agents (one file each)
    researcher.md (sonnet)  recon-analyst.md (haiku)  exploit-dev.md (opus)
    verifier.md (opus)      reverser.md (opus)
  lib/
    bootstrap.sh             thin loader: sets RC2_ROOT, sources the libs below
    common.sh                colors, run-dir resolve, UTC time, flag + target.env helpers
    tools_log.sh             shared logs/tools.jsonl readers (rc2_tl_*)
    env.sh                   .env loading, SecLists
    htb.sh                   token refresh, machine resolve/spawn, VPN pre-flight, flag watcher
    run.sh                   run-dir scaffold, prompt assembly, resilient run loop
    hook_log.sh              force-log every tool call + result; anti-DoS repeat guard
  scripts/
    watch.sh                 live run viewer (reasoning + every tool call/result)
    agents.sh                merged feed of ONLY the non-solver agents' responses (oversee+auditor+sub-agents); read-only
    oversee.sh               supervisor/critic loop -> writes supervisor.md (2nd terminal)
    auditor.sh               epistemic/conclusiveness auditor loop -> auditor.md (auto; pushes via the hook)
    report.sh                writeup.md: narrative (banner+chain+facts) + metrics   (auto on exit)
    analyze_run.sh           failure classifier -> failure_analysis.md/.json  (auto on exit)
    rag.sh                   cross-run memory: grep your own past runs (+ reference/)
    machine.sh               HTB API util: info|ip|spawn|active|stop|reset|submit <name>
    burp.sh                  optional Burp-over-MCP (up|status|down|restart)
    install_tools.sh         one-shot Kali toolset install (core|max|--check)
    conv_fmt.py              stream-json -> readable transcript
    auto_pr.sh               optional dev Stop-hook: branch->PR->merge (personal, gitignored)
    lib/htb_api.sh           HTB API client (resolve/spawn/submit, name->id)
  tools/env-setting/
    set_token_from_har.sh    HAR -> aud:6 labs token -> .env
    check_token.sh           validate the token against the live API
  reference/
    surface-signals.md       observation->environment->direction; consulted when ports are thin (not a playbook)
  har/                       drop HTB devtools HARs here        (gitignored)
  runs/<slug>/               per-box workspace, created at run   (gitignored)
```

Each run directory (the agent's cwd and memory):

```
runs/<slug>/
  target.env                 sourceable facts: target_ip, machine_name, id, os, difficulty
  worldmodel.md              VERIFIED facts only
  hypotheses.md              ranked attack board (per-hypothesis evidence budgets)
  journal.md                 append-only decision trail   journal.archive.md (rolled-out history)
  flags.txt                  user=<hex> / root=<hex>  (auto-submitted)
  writeup.md                 narrative + metrics (report.sh)   failure_analysis.md/.json (analyze_run.sh)
  supervisor.md              reviewer verdicts, if oversee.sh is running (solver follows it)
  auditor.md                 conclusiveness-audit findings, if auditor.sh is running (hook pushes the solver to read it)
  status.md                  auto snapshot of the current situation, refreshed every ~10 min
  target_health.md           auto UP/DOWN/MOVED box signal (read on mass connection failures)
  recon/ enum/ loot/ exploit/ reversing/ research/ tools/ bin/ notes/ cache/   raw evidence (+ run-local scratch)
  logs/                      conv.jsonl, tools.jsonl, raw/, system_prompt.txt, flag_submit.log
  .claude/                   settings.json (logging hook) + agents -> ../../.claude/agents
```

## Design choices

- **Research is first-class.** The agent is expected to hit the live internet — CVEs, vendor
  advisories, exploit code, Google dorks — and to *read exploit code before running it*. See
  [`doctrine/20-research-and-dorking.md`](doctrine/20-research-and-dorking.md).
- **Multiple models by role.** Cheap bulk parsing on haiku, research on sonnet, hard
  reasoning and verification on opus — assigned per sub-agent, tunable per box.
- **tmux and herdr, each per its need.** tmux (zero-dependency, default) does all in-box
  session work: the `_main` watch session, the agent's interactive sessions (reverse shells,
  `msfconsole`, the `_dbg` gdb session), and the `_oversee` loop. (The VPN is a separate
  `openvpn` daemon, not tmux.) [herdr.dev](https://herdr.dev/) is the optional outer/operator
  runtime for hosting hunts as disconnect-surviving, status-aware sessions and across multiple
  machines; its in-process agent coordination overlaps Claude Code's native sub-agents, so it's
  not used for that. Full division of labor in `CLAUDE.md`.
- **Standalone.** No runtime dependency on any sibling project — the HTB API client, HAR
  token extractor, and log renderer are vendored into this tree, and it reads only its own
  `.env`. The design lineage is redcat1, but deleting redcat1 does not affect redcat2. The
  one external resource is the shared SecLists wordlist tree at `$SECLISTS`.

## Extending

- **Change behavior** → edit a `doctrine/*.md` file.
- **Add a specialist model/role** → add a `.claude/agents/<name>.md`.
- **Add plumbing** (reporting, a supervisor, a different lab API) → add to `lib/` and wire in
  `hunt`. Nothing about the loop assumes HTB specifically beyond `lib/bootstrap.sh`.

## Reversing (IDA + gdb)

For boxes with a binary, `doctrine/60-reversing.md` enforces an **export-first** workflow:
bulk-decompile with IDA Pro 9.3 (via the ida-pro-mcp server) to files under `reversing/`,
`grep` those locally for logic and strings, and query IDA over MCP only for targeted
follow-ups — far cheaper in tokens than round-tripping every function. The `reverser`
sub-agent owns this and returns just the primitives that matter. Dynamic analysis uses gdb
(with its plugins) driven inside a dedicated `<tmux_base>_dbg` tmux session. IDA and its MCP
are installed separately by you; `~/.local/bin/{ida,idat}` wrappers point at the install.

## Oversight & memory

- **Supervisor/critic** (`scripts/oversee.sh <slug> ["directive"]`, 2nd terminal) — an opus
  reviewer reads the hunt's logs and living files each tick and, **only when it sees drift**,
  writes `supervisor.md` with a STATUS / STOP / DO-NEXT verdict. The solver reads that file and
  course-corrects (doctrine `10-hunt-loop.md`). It's the long-horizon complement to the in-loop
  `verifier`, catching rabbit holes the solver can't see from inside. It never touches the target.
- **Epistemic auditor** (`scripts/auditor.sh`, auto-started alongside oversee) — a second,
  orthogonal opus reviewer that audits **evidence quality**, not strategy: reading the raw logs, it
  asks of every vector the solver treats as dead whether the mechanism *actually answered* or was
  abandoned on an **inconclusive** result (a test that FAULTed / timed out / was blocked and never
  ran). On a mismatch it writes `auditor.md` and the hook **pushes** the solver to read it (warn →
  hard block if ignored). It is the mid-run, finer-grained counterpart to the surrender gate below.
- **The guard** (**opt-in — off by default**) — mechanical enforcement of the evidence-budget doctrine,
  covering **both** ways a hard box is lost. *Against over-grinding:* a per-call **hook** (repeat / stall
  / ceiling / frozen → warn or block, one-shot override), an out-of-band **sameness judge** (sonnet/haiku
  freezes a hypothesis it rules a dead loop), and the supervisor **gate** (same-focus consensus → tighten).
  *Against premature surrender on a surface it pruned too shallowly* (what sank Nimbus — "CodeBuild is a
  mock" from one fast build, when `privilegedMode=true` was the root path): a **surrender gate** that, on a
  clean-exit blocker, has an independent opus re-audit the weak negatives + the **privilege map** and
  re-open a shallow higher-privilege dismissal. The solver is oriented to **hunt the privilege delta**
  (what runs above me, and does my input reach it) and to record negatives with how-deeply-tested.
  Enforcement is a two-tier switch — operator **floor** (`RC2_GUARD` env) ⊔ oversee **live**
  (`scripts/guard.sh`, secret-tagged), `effective = max`. Turn it on with `RC2_GUARD=warn ./hunt Box`
  (nudges) or `RC2_GATE=1 ./hunt Box` (full auto). See [GUIDE §4a](docs/GUIDE.md).
- **Retrospectives** (auto on exit, or standalone) — `report.sh` writes metrics into `writeup.md`
  (wall time, tool/Task counts, per-phase timing); `analyze_run.sh` classifies *why* a run went
  as it did (tool-execution / state-mgmt / planning / hypothesis / idle-wait) into
  `failure_analysis.md`+`.json`. These are what make a run judgeable.
- **Cross-run memory** (`scripts/rag.sh <query>`) — greps the agent's own past runs
  (journals, world models, hypotheses, writeups, failure analyses) so a service, version, error,
  or technique it met before has a recalled answer. Doctrine `20` tells the agent to check it
  before researching live. `-p` also searches `reference/` (surface-signals) and the shared
  PayloadsAllTheThings / GTFOBins refs.
- **Periodic status** — a background snapshotter rewrites `status.md` every ~10 min
  (`STATUS_INTERVAL`) with the current flags, phase, hypothesis counts, recent journal lines,
  recent tool calls, tmux sessions, and artifact counts. Operator view + resume aid; the agent's
  own record stays in `journal.md`.
- **HTB API util** (`scripts/machine.sh`) — once a token exists (from the HAR pipeline), do
  machine ops by name without a full hunt: `info`, `ip`, `spawn` (waits 15×3 min = 45 min for the
  IP, like redcat1), `active`, `stop`, `reset`, `submit <flag>`. Names resolve to ids automatically.

## Status

Scaffold complete and syntax-checked: the hunt loop + doctrine, multi-model sub-agents, HAR token
automation, restart loop, live viewer (`watch.sh`), optional Burp (`burp.sh`), reversing doctrine
+ `reverser`, the supervisor (`oversee.sh`), retrospectives (`report.sh`/`analyze_run.sh`), and
cross-run memory (`rag.sh`). Helper scripts functionally tested on seeded runs, and the loop has
run against live HTB boxes (at least one solved end to end, user+root). Doctrine wording and
sub-agent model assignments are still being tuned from run retrospectives.
