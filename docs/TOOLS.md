# redcat2 — Tool & Script Reference

Complete usage for every executable in the tree: the launcher, the helper scripts, the HTB API
utilities, the token pipeline, and the sourced libraries. For the big picture read
[`GUIDE.md`](GUIDE.md); this file is the per-tool detail (every flag, env var, and example).

Conventions: run everything from the repo root (`/home/kali/redcat2`). A `<name>` argument is an
HTB machine name (case-insensitive resolution; the run dir keeps the real casing), a run **slug**,
or an IP. Most read-only tools default to the **newest** run under `runs/` when given no argument.

Contents: [hunt](#hunt) · [watch.sh](#watchsh) · [oversee.sh](#overseesh) · [report.sh](#reportsh)
· [analyze_run.sh](#analyze_runsh) · [rag.sh](#ragsh) · [machine.sh](#machinesh) ·
[burp.sh](#burpsh) · [install_tools.sh](#install_toolssh) · [auto_pr.sh](#auto_prsh) ·
[conv_fmt.py](#conv_fmtpy) · [htb_api.sh](#scriptslibhtb_apish) · [token pipeline](#token-pipeline)
· [libraries](#libraries-sourced-not-run) · [PATH launchers](#path-launchers-reversing)

---

## `hunt`

The launcher. Runs one autonomous hunt (headless Claude Code) against a target until `user.txt` +
`root.txt`, or a written blocker.

```
./hunt [--fresh] <machine_name|ip> [orchestrator_model] [extra notes]
```

| arg | default | meaning |
|---|---|---|
| `<machine_name\|ip>` | — (required) | HTB name (API resolves + spawns; needs a token) or raw IP (IP-only mode: no spawn/submit) |
| `[orchestrator_model]` | `opus` | orchestrator model; sub-agents pick their own |
| `[extra notes]` | — | free-text hint appended to the launch prompt |
| `--fresh` | — | archive any existing run for this target to `runs/<slug>.bak.<epoch>`, start clean |

**Environment toggles**

| var | default | effect |
|---|---|---|
| `MAX_RESTARTS` | 20 | auto-relaunch budget on crash/overflow (non-zero exit) |
| `NO_RESTART` | 0 | `1` = run the agent exactly once |
| `NO_OVERSEE` | 0 | `1` = don't start the supervisor |
| `NO_STOP` | 0 | `1` = on solve, keep the HTB machine up (default: terminate it) |
| `OVERSEE_INTERVAL` | 600 | supervisor review cadence (s) |
| `STATUS_INTERVAL` | 600 | `status.md` snapshot cadence (s) |
| `IP_WAIT_TRIES` | 15 | spawn/IP poll attempts |
| `IP_WAIT_INTERVAL` | 180 | seconds between IP polls (15×180s = 45 min) |
| `HAR_SRC` | Windows DevTools folder | where to import the newest HAR from |
| `FRESH` | — | same as `--fresh` |

```bash
./hunt Management                      # name → resolve/spawn, opus orchestrator
./hunt Management sonnet               # cheaper orchestrator
./hunt 10.10.11.42 opus "custom web app on 443"
IP_WAIT_TRIES=3 IP_WAIT_INTERVAL=20 ./hunt Fast     # short spawn wait for a quick box
NO_OVERSEE=1 ./hunt Management         # no supervisor
./hunt --fresh Management              # archive + restart clean
```

Resume is implicit: re-run the same target and it re-enters `runs/<slug>/` and continues from the
three living files. On exit it writes `writeup.md` + `failure_analysis.*`. Creates `runs/<slug>/`
where **slug = the real machine name, case preserved** (e.g. `runs/Management`; spaces → `_`).

---

## `watch.sh`

Live feed of a hunt in a second terminal: the agent's reasoning interleaved with every tool call
and its output.

```
scripts/watch.sh [<name|ip|rundir>]
```

| env | default | effect |
|---|---|---|
| `FULL` | 0 | `1` = print each tool's whole output (default: last `MAX` lines) |
| `MAX` | 200 | lines of output shown per tool call |
| `NOCONV` | 0 | `1` = tool feed only, suppress the reasoning stream |

```bash
scripts/watch.sh                 # newest run
scripts/watch.sh Management      # by name / slug
FULL=1 scripts/watch.sh          # complete outputs
NOCONV=1 scripts/watch.sh        # just the tool calls
```

Reads `logs/conv.jsonl` (reasoning, via `conv_fmt.py`) + `logs/tools.jsonl` (tool calls). Needs
`python3` for the reasoning stream; without it you get the tool feed only. Live progress bars
(nmap/hashcat/ffuf) render only in the hunt's tmux session — `tmux attach -t rc2_<slug>_main`.

---

## `oversee.sh`

Supervisor/critic loop: an opus reviewer reads the running hunt's logs + living files and writes
advice only when it sees drift. The solver follows a newer verdict. `hunt` auto-starts one; run a
second by hand to inject an operator directive.

```
scripts/oversee.sh <name|slug> ["operator directive"]
```

| env | default | effect |
|---|---|---|
| `OVERSEE_INTERVAL` | 600 | review cadence (s) |
| `OVERSEE_MODEL` | opus | reviewer model |
| `ONESHOT` | 0 | `1` = one assessment then exit |
| `OP_NOTE` | — | operator directive (alt to the positional arg) |

```bash
scripts/oversee.sh Management
scripts/oversee.sh Management "focus the SSTI on /render, not the login"
OVERSEE_INTERVAL=300 scripts/oversee.sh Management
ONESHOT=1 scripts/oversee.sh Management
```

Writes `runs/<slug>/supervisor.md` (latest verdict) + `logs/supervisor.jsonl` (history). Never
touches the target. **Pass the run slug exactly** — it resolves `runs/<slug>` directly (with the
case-preserving slug, use the real machine name, e.g. `Management`).

---

## `report.sh`

Retrospective metrics → injected into `writeup.md`: wall time, tool/Task counts, per-phase
breakdown, best-effort token/cost. Auto-run by `hunt` on exit; safe to run standalone.

```
scripts/report.sh <rundir>
```

```bash
scripts/report.sh runs/Management
```

Deterministic over `logs/tools.jsonl` + `logs/phases.log`.

---

## `analyze_run.sh`

Failure classifier → `failure_analysis.md` + `.json`. Complements `report.sh` (which measures) by
classifying **why** a run went as it did. Auto-run by `hunt` on exit; safe standalone. Always
exits 0.

```
scripts/analyze_run.sh [<rundir|name|ip>]      # default: newest run
```

Categories: `tool_execution` (timeouts/non-zero exits), `state_mgmt` (repeated command/result),
`planning` (long stretch, no confirmed hypothesis), `hypothesis` (many frozen/refuted),
`idle_wait` (content-free "waiting" turns), `observation` (big output, no follow-up win).

```bash
scripts/analyze_run.sh                 # newest
scripts/analyze_run.sh Management
```

---

## `rag.sh`

Cross-run memory: ripgrep retrieval over the agent's **own** past runs (`journal.md`,
`worldmodel.md`, `hypotheses.md`, `writeup.md`, `failure_analysis.md`, `notes/`, `research/`). No
vector DB — the agent recalls "have I seen this service/tech/error before, and what worked".

```
scripts/rag.sh [-p] <query...>
```

| flag / env | effect |
|---|---|
| `-p` | also search shared refs (PayloadsAllTheThings, GTFOBins) |
| `SCOPE=runs/<slug>` | restrict the search to one run dir |

```bash
scripts/rag.sh grafana 8.3 ssrf
scripts/rag.sh -p "sudo tar"                 # include GTFOBins/PATT
SCOPE=runs/Management scripts/rag.sh ldap
```

By design it ships no methodology corpus — redcat2 researches the live internet and remembers only
its own evidence.

---

## `machine.sh`

HTB machine ops over the API, outside a full hunt. Token comes from `.env`; a name resolves to an
id via the profile endpoint, a numeric id is used as-is.

```
scripts/machine.sh <cmd> <name|id> [flag]
```

| cmd | args | does |
|---|---|---|
| `info` | `<name\|id>` | profile: name/id/os/difficulty/ip/retired/points |
| `ip` | `<name\|id>` | the IP if known (active/spawned), else a hint |
| `spawn` | `<name\|id>` | spawn + wait for IP (15×3 min = 45 min), print it |
| `active` (alias `status`) | — | the currently active machine + IP |
| `stop` (alias `terminate`) | `<name\|id>` | terminate |
| `reset` | `<name\|id>` | reset |
| `submit` (alias `own`) | `<name\|id> <flag>` | submit a flag |

`IP_WAIT_TRIES` / `IP_WAIT_INTERVAL` tune the spawn wait (same as `hunt`).

```bash
scripts/machine.sh info Management
scripts/machine.sh spawn Management
scripts/machine.sh active
scripts/machine.sh submit Management 8f434346...   # or: own
```

---

## `burp.sh`

**Optional.** One command → Burp Suite Pro usable over MCP. Run it *before* `./hunt` on a
web-heavy box so the agent inherits `mcp__burp__*` (Repeater/Intruder/Scanner/session handling).
Launches Burp + the BurpMCP-Ultra extension in a persistent tmux session under headless Xvfb, waits
for the MCP server, and registers it with Claude Code at user scope.

```
scripts/burp.sh [up|status|down|restart]        # no arg = up (idempotent)
```

| cmd | does |
|---|---|
| `up` | launch + register (re-registers if already running) |
| `status` | tmux session, live MCP port, claude registration |
| `down` | stop the Burp tmux session (Xvfb torn down with it) |
| `restart` | down + up |

Config in `.env`: `BURP_MCP_TOKEN` (required — from Ultra's Server tab, stable). Overrides:
`BURP_JAR`, `BURP_LOADER`, `BURP_PROJECT`, `BURP_TMUX`, `BURP_DISPLAY` (`xvfb`, or `:0` for WSLg).
The Burp install itself is a shared external resource, not part of redcat2.

```bash
scripts/burp.sh up        # then: ./hunt <webby-box>
scripts/burp.sh status
scripts/burp.sh down
```

---

## `install_tools.sh`

Install the Kali toolset the doctrine expects (recon → root, plus Cloud + AD). Idempotent; a single
failure never aborts the rest. Target OS: Kali Rolling (apt + pipx + go + git).

```
scripts/install_tools.sh [core|max|--check]
```

| arg | does |
|---|---|
| (none) / `max` | full toolset: apt + pipx + go + git + SecLists + extras |
| `core` | apt packages only (lightweight base) |
| `--check` | only print what is present / missing |

| env | effect |
|---|---|
| `SKIP_CLOUD=1` | skip aws/az/gcloud CLIs |
| `SKIP_PYENV=1` | skip the redcat venv bootstrap |

```bash
scripts/install_tools.sh --check
scripts/install_tools.sh core
SKIP_CLOUD=1 scripts/install_tools.sh
```

---

## `auto_pr.sh`

**Dev-workflow automation, not part of a hunt.** Wired as a Claude Code **Stop hook** (end of each
turn), it turns every turn that changed a tracked file into a merged PR: branch `auto/<timestamp>`
→ commit (with attribution) → push → `gh pr create` → `gh pr merge --squash --delete-branch` →
back to `main`. Safe no-op when the tree is clean, when `gh`/the remote are unavailable, or when
already on an `auto/*` branch. Always exits 0 (never fails the session).

```
bash scripts/auto_pr.sh          # reads hook JSON on stdin (session_id); run by hand for a one-off
```

| env | default | effect |
|---|---|---|
| `AUTO_PR_DISABLE` | 0 | `1` = skip this run entirely |
| `AUTO_PR_MERGE` | `squash` | merge method: `squash` \| `merge` \| `rebase` |
| `AUTO_PR_MODEL` | `Claude` | attribution model name in the commit trailer |
| `AUTO_PR_SESSION_URL` | — | explicit `Claude-Session` URL (else built from the hook's `session_id`) |

Wiring lives in a personal, gitignored `.claude/settings.local.json`:

```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/auto_pr.sh\"", "timeout": 180 } ] } ] } }
```

Notes: after creating/editing `.claude/settings.local.json` the hook activates only on session
reload (`/hooks` or restart) — the settings watcher wasn't watching `.claude/` at startup. A running
`./hunt` (cwd = `runs/<slug>/`, gitignored) does **not** trigger it. Expect one merged PR per
file-changing turn; disable with `AUTO_PR_DISABLE=1` for a one-off.

```bash
AUTO_PR_DISABLE=1 ...                            # (hook reads env; set in the hook command to pause)
AUTO_PR_MERGE=merge bash scripts/auto_pr.sh      # manual one-off, merge commit
```

---

## `conv_fmt.py`

Internal renderer: turns `claude -p --output-format stream-json` (one JSON event per line) into
readable, colored lines. Reads JSONL on stdin, writes line-buffered to stdout. Never raises on a
bad line (garbage passes through dim). Used by `watch.sh` (with `--no-tools` to show only
reasoning). Falls back to raw `cat` if unavailable.

```bash
tail -F runs/Management/logs/conv.jsonl | python3 scripts/conv_fmt.py            # full
tail -F runs/Management/logs/conv.jsonl | python3 scripts/conv_fmt.py --no-tools # reasoning only
```

---

## `scripts/lib/htb_api.sh`

Thin HTB API helper — source it, or run a subcommand. Auth is an HTB **App Token** (create at
app.hackthebox.com → Account Settings → "Create App Token"), put in `.env` as `HTB_TOKEN`. Endpoints
verified against the htb-operator CLI: machine/vm on `v4`, flag submission + listing on `v5`
(`labs.hackthebox.com`). `machine.sh` and `hunt` call it for you — reach for it directly only when
scripting raw API calls.

```
scripts/lib/htb_api.sh {profile|active|spawn|terminate|reset|own} [args]
```

---

## Token pipeline

The labs token is hands-off during a hunt (`hunt` imports the newest HAR and refreshes it when
stale). Use these directly when a token expires or you want to validate `.env`.

**`tools/env-setting/set_token_from_har.sh`** — extract + verify the Bearer token from a DevTools
HAR, then write it to `.env`. In the browser (app.hackthebox.com, logged in): DevTools → Network →
right-click a request → *Save all as HAR* → pass it here.

```
tools/env-setting/set_token_from_har.sh <file.har>
```

**`tools/env-setting/check_token.sh`** — decode `HTB_TOKEN` (aud/exp), live-test labs auth, and
check the other keys a solve relies on. Exit 0 if the token authenticates, 1 otherwise.

```
tools/env-setting/check_token.sh
```

---

## Libraries (sourced, not run)

Loaded by `lib/bootstrap.sh`; edit the function, not the launcher.

| file | provides |
|---|---|
| `lib/bootstrap.sh` | library loader; sets `$RC2_ROOT`, sources the rest |
| `lib/common.sh` | ANSI colors, `rc2_resolve_rundir`, `rc2_to_epoch` |
| `lib/env.sh` | `.env` loading, SecLists, flag helpers |
| `lib/htb.sh` | token refresh, machine resolve/spawn, VPN pre-flight, and `rc2_flag_watcher` — auto-submits user/root flags via two channels (`flags.txt` + enforced scan of logged `user.txt`/`root.txt` reads), persistent dedup in `logs/.submitted`, retry on auth-rejected submit |
| `lib/run.sh` | run-dir scaffold (the case-preserving slug), prompt assembly, resilient run loop, status writer, oversee launch |
| `lib/hook_log.sh` | per-run PreToolUse/PostToolUse hook: force-logs every call to `logs/tools.jsonl` + `logs/raw/`, and blocks (exit 2) identical-command/identical-result repeats (anti-stuck/throttle/DoS) |

---

## PATH launchers (reversing)

Not in this repo — installed on the box and used by the reversing doctrine (see
[`GUIDE.md` §9](GUIDE.md) and `doctrine/60-reversing.md`).

| launcher | purpose |
|---|---|
| `ida` / `ida64` / `idat` / `idat64` | IDA Pro GUI / text (export-first: dump pseudocode + strings to `reversing/<binary>/`, grep locally) |
| `gdb-pwndbg` (default) / `gdb-gef` / `gdb-peda` | gdb with a plugin preloaded; or `init-pwndbg`/`init-gef`/`init-peda` inside a plain gdb. No plugin auto-loads — pick one per session. Run in the `rc2_<slug>_dbg` tmux session |
