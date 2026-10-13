# redcat2 - Developer Guide

> The deep "why". For *operating* redcat2 (commands, flags, setup, troubleshooting) read
> [`GUIDE.md`](GUIDE.md); for per-tool detail [`TOOLS.md`](TOOLS.md); for working *on the code*
> [`../CLAUDE.md`](../CLAUDE.md). This document explains **how the whole pipeline fits together and
> why it is shaped the way it is** - the design goals, the failure modes it is built to survive, and
> the invariants you must preserve when you change it. Diagrams are plain ASCII, left-aligned (no right
> wall), so they stay aligned in any monospace viewer.

---

## 1. The thesis

redcat2 is an **autonomous offensive-research agent** that solves HTB-style machines Easy -> Insane.
The engine is Claude Code itself (`claude -p`, headless). The design bet is one sentence:

```
  Hard boxes are not lost for lack of techniques.
  They are lost when the agent STOPS REASONING - by grinding a disproven idea, or by
  surrendering on a surface it pruned from the search space without actually disproving it.
```

redcat1 (the predecessor) was a fixed 8-phase pipeline + per-service playbooks. It stalled the moment a
box needed something off-script. redcat2 is the deliberate opposite: an **epistemic** loop
(observe -> hypothesize -> research -> experiment -> verify -> reflect) with **no playbook library**. The
methodology lives in prose (`doctrine/`), and the job of the *code* is only to (a) run the loop
resiliently and (b) mechanically enforce the few invariants that prose alone cannot hold.

**Prime principle - generalize, never pre-bake.** If you are tempted to encode a solve, a chain, or a
decision as a static script or lookup table, stop: make it something the model reasons through, adapting
to the live target. Scripts are fine for mechanical plumbing (logging, atomic writes, token automation);
they are never the agent's attack logic. (See the `generalization-over-playbooks` memory and section 6.)

---

## 2. Three layers

Read these together. The brain is prose; the team is prompts; the memory is files on disk.

```
  [ BRAIN ]   doctrine/*.md   ->   the system prompt
      00 prime  10 hunt-loop  20 research  30 tools  40 memory  50 subagents  60 reversing
      << edit these files to change how the agent THINKS >>
         |
         |  --append-system-prompt
         v
  [ SOLVER ]  claude -p   (Opus, the orchestrator)
      runs the Hunt Loop until user.txt + root.txt are VERIFIED
         |
         |  delegates bulk / self-contained work via the Task tool (answer comes back distilled):
         |     researcher(sonnet)  recon-analyst(haiku)  exploit-dev/verifier/reverser(opus)
         |
         |  reads + rewrites memory every loop
         v
  [ MEMORY ]  runs/<slug>/   (the disk IS the memory)
      worldmodel.md   hypotheses.md   journal.md         (3 living files)
      ledger.json (machine mirror)    logs/accounting.json (guard counters)
      recon/ enum/ loot/ exploit/ reversing/ research/ ...
```

- **Brain = `doctrine/*.md`.** `hunt` concatenates them in numeric order into `--append-system-prompt`.
  A new file is picked up automatically. This is the entire methodology; it is intentionally *not* a
  playbook. To change behaviour, edit doctrine - not the launcher.
- **Team = `.claude/agents/*.md`.** Multi-model sub-agents the orchestrator delegates to via the Task
  tool, to keep bulk output and self-contained work out of its own context window.
- **Memory = `runs/<slug>/`.** The three living files + machine-readable mirrors + raw evidence. This is
  what lets a hunt outlive a single context window - the core requirement for Insane boxes, where the
  transcript *will* be summarised or a fresh instance *will* take over.

---

## 3. The pipeline - what `./hunt` does, and why

```
  ./hunt [--fresh] <machine|ip> [model] [notes]
    |
    v
  bootstrap.sh  sources lib/:  guard_lib -> common -> tools_log -> env -> htb -> run
    |
    |-- rc2_load_env          .env (token, SecLists) + guard calibration defaults (env.sh)
    |-- rc2_ensure_htb_token  HAR -> aud:6 bearer, verified, written to .env   (hands-off)
    |-- rc2_resolve_target    HTB API resolve/spawn (wait up to 15 x 180s = 45m)
    |-- rc2_scaffold          runs/<slug>/ : seed 3 living files + ledger.json +
    |                         logs/accounting.json + .guard_secret + .claude/settings.json(hook)
    |-- rc2_ensure_vpn        openvpn --daemon if HTB_OVPN set; reachability pre-flight
    |-- rc2_htb_owned_init    read owned-flag status -> logs/.flag_mode = live | defer
    |
    |-- rc2_flag_watcher &    bg: submit user/root as captured (dedup incl. per-value bad-dedup)
    |-- rc2_status_writer &   bg: status.md every ~600s + live confirmed-path -> writeup.md
    |-- rc2_guard_watcher &   bg: sameness judge + contradiction signal  (only if guard on)
    |-- rc2_launch_oversee    supervisor (herdr pane, else tmux session)
    |
    v
  rc2_run_loop
    .----------------------------------------------------------------------.
    |  claude -p  (stream-json, --dangerously-skip-permissions)            |
    |    every tool call passes through lib/hook_log.sh (PreToolUse):      |
    |    force-log + anti-DoS repeat guard + P1 accounting/guard           |
    '----------------------------------------------------------------------'
         |  on exit:
         |    rc2_solved?            -> both flags present AND accepted -> DONE
         |    rc=0 (clean blocker)?  -> SURRENDER GATE: re-audit, maybe REOPEN + loop
         |    cyber safeguard flag?  -> relaunch fresh (cap CYBER_MAX_RETRIES)
         |    rc!=0 (crash/overflow)?-> relaunch, resume from disk (cap MAX_RESTARTS)
         v
  cleanup (trap EXIT)
    stop watchers | final flag sweep | final status | report.sh + analyze_run.sh
    if rc2_solved  -> terminate HTB machine (NO_STOP=1 keeps it) + tear down tmux
    else           -> PRESERVE run dir + tmux for resume
```

Key design choices in the pipeline:

- **Resume is implicit and the disk is the memory.** Re-launching the same target re-enters the run
  dir; the three living files + `ledger.json` carry all state. `--fresh` archives the old run to
  `runs/<slug>.bak.<ts>` (never deleted) and starts clean.
- **The run loop is resilient by default.** A crash or context overflow (`rc!=0`) auto-relaunches a
  fresh headless agent that resumes from disk (`MAX_RESTARTS`, default 20). A *clean* exit (flags, or a
  written blocker) is respected - **except** it first passes the surrender gate (section 4). A
  cyber-safeguard content flag re-trips on a fresh session, so those relaunches are capped
  (`CYBER_MAX_RETRIES`).
- **The hook is model-independent.** `lib/hook_log.sh` runs on *every* tool call as a separate process,
  so logging + the guard happen regardless of what the model decides to do or forget to do.
- **SOLVED means accepted, not merely captured.** `rc2_solved` requires both flags *submitted and
  accepted* by the lab (`logs/.submitted` has bare `user`+`root`, not `kind:bad:<flag>`), falling back
  to presence only in IP-only mode. A captured-but-wrong/stale flag no longer terminates the machine (a
  bug that once killed a box whose root was rejected).

### The Hunt Loop (doctrine 10)

```
   ORIENT -> RESEARCH? -> EXPERIMENT -> OBSERVE -> VERIFY -> REFLECT --+
     ^                                                                 |
     +----------------------------  repeat  ---------------------------+

   ORIENT    : pick the highest expected-value hypothesis; orient by the PRIVILEGE
               DELTA - "what runs ABOVE me, and does my input reach it?" - across all domains
   RESEARCH? : if the experiment depends on anything not known cold -> researcher sub-agent
   EXPERIMENT: the smallest test that DISTINGUISHES hypotheses (not one that confirms a hope)
   OBSERVE   : capture FULL raw output to disk; distill walls via recon-analyst
   VERIFY    : prove it truly happened (a command running is not a result)
   REFLECT   : update worldmodel / hypotheses / ledger; re-rank; detect rabbit holes
```

---

## 4. The guard - the centrepiece

Everything above is redcat1-plus-reasoning. The guard is what the recent work added, and the part most
worth understanding. **It exists because prose discipline alone did not stop the two ways a hard box is
actually lost.** It is opt-in and OFF by default.

### 4.1 The two failure modes (both observed on "Nimbus")

```
  FAILURE 1 : OVER-GRIND                  FAILURE 2 : PREMATURE SURRENDER
  ----------------------                  -------------------------------
  drill one disproven hypothesis          dismiss a surface on thin evidence
  forever -- Nimbus burned 832 calls      -- "CodeBuild is a mock" from ONE 0.5s
  on one container-escape across 6         build -- record that shallow negative
  sessions; solved boxes finished in       as fact, never re-open it, then declare
  ~186-416 calls.                          a confident (WRONG) blocker.

     caught by:                               caught by:
       hook repeat / stall / ceiling            surrender gate (re-audit negatives)
       sameness watcher (freeze)                negative provenance          (A)
       oversee consensus gate                   privilege-delta orientation  (B)
                                                open-enumeration reflex       (E)
```

A third, subtler one surfaced later:

```
  FAILURE 3 : CONFIRMATION GRINDING  ("fix the want, then solve")
  --------------------------------------------------------------
  the agent fixes a desired MECHANISM (e.g. "CodeBuild -> docker.sock -> host") and grinds
  to achieve it, ignoring its own high-confidence evidence that the mechanism is absent -
  and checks only for the primitive it WANTED instead of enumerating what is present.
     caught by: the sameness judge's `contradiction` signal (section 4.5)
```

### 4.2 Layers (who watches what)

```
  [ HOOK ]            hook_log.sh    -- per tool call, mechanical, cheap           (FM1)
      counts experiments/surfaces; warn|block on a literal action repeated
      RC2_REPEAT_FREEZE times, a frozen hypothesis, or the global RC2_CEIL.

  [ SAMENESS WATCHER ] rc2_guard_watcher + JUDGE.md  -- out-of-band, sonnet    (FM1/FM3)
      on stall: judge rules SAME -> persistent arbiter freeze | VARYING -> let run.
      ALSO emits a `contradiction` signal -> supervisor tick (section 4.5).

  [ OVERSEE GATE ]    oversee.sh + OVERSEER.md  -- trajectory, opus                (FM1)
      only after RC2_GATE_N consecutive same-FOCUS rabbit-hole reviews does it
      raise the LIVE guard level (re-asserted each tick; released when on-track).

  [ SURRENDER GATE ]  rc2_surrender_gate + SURRENDER.md  -- on clean-exit, opus    (FM2)
      before a blocker is accepted: re-audit weak negatives + privilege map +
      per-surface effort -> ACCEPT, or name a concrete REOPEN -> relaunch (bounded).

  FM1 = over-grind | FM2 = premature surrender | FM3 = confirmation grinding
```

Why four layers, not one: they act at **different granularities and cadences** - per-call (hook),
per-stall (watcher), per-review (oversee), per-surrender (gate) - and against **opposite** failures. A
single mechanism cannot be both "stop drilling" and "don't give up".

### 4.3 The two-tier switch - who controls enforcement

Enforcement level is never one global knob. It is the **stronger of two tiers**, so three parties have
exactly the authority they should:

```
  operator  --sets-->   FLOOR  =  RC2_GUARD env  (off | warn | block), set at launch
                          |         the solver and the supervisor can NEVER go below it
                          |
  oversee   --sets-->   LIVE   =  logs/guard.mode (via scripts/guard.sh), tag-authenticated
                          |         by logs/.guard_secret  (a dotfile the solver may not read)
                          v
                     EFFECTIVE =  max(FLOOR, LIVE)       [ off  <  warn  <  block ]
                          |
                          +--->  what the hook actually enforces
```

- The **operator** guarantees a minimum. The **supervisor** can only *tighten*, dynamically, on
  evidence. The **solver can never weaken its own guard** (the floor is an env var it can't change; the
  live tier is secret-tagged so it can't forge it). `scripts/guard.sh <run> show` prints all three.
- A solver that tampers with the live file at worst drops it to the floor for <= 1 oversee cycle
  (oversee re-asserts). A genuinely *adversarial* same-uid solver would need OS separation to stop -
  out of scope; the guard assumes an earnest-but-fallible model.

### 4.4 State model - intent vs accounting

The single most important structural rule: **the thing the agent writes and the thing the harness
enforces on are different files.**

```
  ledger.json           "INTENT"      <-- the SOLVER owns it (hand-written JSON)
      current_hypothesis                  mirrors hypotheses.md for the machine to read
      hypotheses{claim,status,freeze}     confirmed_path{summary,how,yields}  (replayable)
      negatives{fact,confidence,tested}   override{hypothesis,reason,nonce}   (one-shot)
         |
         |   the hook/harness NEVER trusts this JSON for its counters
         v
  logs/accounting.json  "ACCOUNTING"  <-- the HOOK/HARNESS owns it; the solver must NEVER write it
      global{experiments,ceiling,warn_at,overrides_used}   surfaces{domain:count}
      per_hypothesis{spent,repeat_count,last_action_fp}    progress{last_progress_*}
      arbiter_freezes{H}   freeze_candidate   consumed_overrides[]
      supervisor{consecutive_rabbit_hole, gated, last_contradiction_fp, ...}
```

Why split them: a malformed hand-edit by the solver can corrupt *its* ledger but can **never** corrupt
the counters enforcement rests on, and an arbiter freeze lives in the hook-owned file so the solver
cannot clear it by editing its own ledger (`rc2_is_frozen` checks *both*). Every JSON write goes through
`rc2_json_update` - atomic (tmp+mv) and **fail-open** (a broken file leaves the original and never
bricks the run). That fail-open is deliberate and pervasive: the hook must *always* log and never break
the hunt, even if a lib is missing.

### 4.5 Negatives, replay, and the contradiction signal

Three mechanisms tie the guard to the solver's reasoning:

- **Negative provenance (A).** "X is closed/absent/mock" is a *claim*: it must carry *how deeply tested*
  + a confidence, and the load-bearing ones are mirrored into `ledger.negatives`. A shallow negative is
  a **hypothesis, not a fact** - and a re-open candidate. `rc2_negatives` is the one reader (structured
  list first, free-text grep fallback), used by both the surrender gate and the judge.
- **Confirmed-path replay (re-walk, not script).** `confirmed_path` records each proven step's `how` +
  `yields`. On resume the solver **re-walks** the chain with its own tools, adapting to the respawned
  instance (fresh creds/IDs/flags) - it does **not** run a frozen `.sh`. This is the generalize-not-
  pre-bake principle applied to replay: a chain's non-deterministic parts can only be re-executed by
  reasoning, and the only real validation is an actual model run reaching root again.
- **Contradiction signal (FM3).** The sameness judge also flags when recent actions *presuppose* a fact
  the agent recorded absent/refuted (esp. high-confidence). `rc2_guard_contradiction_signal` then writes
  a supervisor tick: *"you are chasing a want your own evidence refutes - re-test that negative (maybe it
  was shallow, A) or drop the want and open-enumerate (E)."* Debounced per-contradiction.

### 4.6 Knob reference

| knob | default | tier / effect |
|---|---|---|
| `RC2_GUARD` | `off` | operator **floor** (off\|warn\|block); `!=off` also starts watcher + gate + surrender gate |
| `RC2_GATE` | `0` | `1` = oversee may raise the **live** level on consensus; one-switch full-auto |
| `RC2_GUARD_WATCH` | `0` | `1` = run the sameness watcher without a floor (judge/freeze only) |
| `NO_GUARD_WATCH` / `NO_SURRENDER` | `0` | force the watcher / surrender gate off |
| `RC2_REPEAT_FREEZE` | `4` | identical-action repeats on one hypothesis before warn/block |
| `RC2_STALL` | `12` | experiments on one hypothesis with no new evidence before the judge runs |
| `RC2_CEIL` / `RC2_WARN` | `800`/`450` | global experiment hard-stop / warn line (calibration: solved ~186-416) |
| `RC2_BUDGET_DEFAULT` | `8` | per-hypothesis attempt budget seeded into the ledger |
| `RC2_GATE_N` / `RC2_GATE_MODE` | `2` / `block` | consecutive same-focus rabbit-holes -> oversee raises live to this mode |
| `GUARD_JUDGE_MODEL` | `sonnet` | sameness judge model (`haiku` cheaper/coarser) |
| `GUARD_WATCH_INTERVAL` | `180` | watcher cadence (s) |
| `RC2_SURRENDER_MAX` / `RC2_SURRENDER_MODEL` | `2` / `opus` | surrender-gate re-open budget / model |

All calibration defaults live in **one place** - `lib/env.sh`. `RC2_GUARD`/`RC2_GATE`/`RC2_GUARD_WATCH`
are read at point of use (operator intent, not defaults).

---

## 5. Data model & run-dir layout

```
  runs/<slug>/
  |- worldmodel.md      VERIFIED facts only (incl. "## Privilege map"); reason FROM this
  |- hypotheses.md      ranked attack board; one block / hypothesis + evidence budget
  |- journal.md         append-only decision trail (UTC-stamped)
  |- ledger.json        machine mirror (INTENT): current hyp, confirmed_path, negatives, override
  |- flags.txt          user=<hex> / root=<hex>   (truncated each launch; re-captured)
  |- status.md          auto snapshot (~600s) - read-only to the agent
  |- writeup.md         live "Confirmed path" block (above WRITEUP markers) + metrics on exit
  |- supervisor.md      reviewer verdicts (oversee / surrender gate / contradiction) - tick-gated
  |- target.env         sourceable facts (target_ip, machine_id, tmux_base, ...)
  |- recon/ enum/ loot/ exploit/ reversing/ research/ tools/ bin/ notes/   raw evidence
  `- logs/
     |- accounting.json   guard counters (ACCOUNTING - harness-owned)
     |- tools.jsonl       every tool call (pre+post) - forced by the hook
     |- raw/<ts>.out      full result of every call
     |- guard.log         guard actions (freeze / gate / surrender / contradiction)
     |- guard.mode        live guard tier (tagged)       .guard_secret   (0600, solver-forbidden)
     |- .flag_mode        live | defer                   .submitted      (flag dedup incl. :bad:)
     |- .stop             watcher stop sentinel          meta.env        (model, start_epoch)
     `- conv.jsonl  phases.log  flag_submit.log  session_*.log  system_prompt.txt
```

Convention worth preserving: **signals the hook must read fast and without `jq` are plain files**
(`guard.mode`, `.guard_secret`, `.flag_mode`, `.stop`); **structured state read with `jq` is
`accounting.json`**. Keep new state on that split.

---

## 6. Design invariants (do not break these)

1. **Doctrine drives behaviour.** Prefer editing `doctrine/*.md` over hardcoding steps in the launcher.
   The launcher is plumbing; the doctrine is policy.
2. **Generalize, never pre-bake a playbook.** The agent's attack logic is reasoning, not scripts. Teeth
   are for *meta* invariants (budgets, freezes, surrender), not for object-level technique choice.
3. **Mechanical teeth where prose fails.** Evidence budgets were ignored as prose; they work as hook
   enforcement. When a guiding rule keeps being violated, move it from prose to a hook/gate - but keep
   the object-level reasoning the model's.
4. **Opt-in + operator floor.** All enforcement is off by default; the operator sets a floor no layer
   can go below; automation can only tighten; the solver can never weaken its own guard.
5. **Evidence discipline cuts both ways.** Never record an unverified *win* - and never record a shallow
   *negative* as fact. Both prune the search space; a wrong negative is how a solvable box gets called
   blocked.
6. **Intent != accounting.** The solver's hand-written JSON can never corrupt the counters the harness
   enforces on. Writes are atomic and fail-open.
7. **Fail-open, always.** The hook and the guard must never break the hunt. A missing lib, a malformed
   file, a down model call -> degrade to "no enforcement + a loud log", never to a dead run.
8. **The hook is standalone.** `hook_log.sh` sources only the tiny `guard_lib.sh`, guarded, so a lib
   change can never break logging. Keep it minimal.

---

## 7. Code map

```
  hunt                     launcher + resilient loop entry + cleanup/teardown
  lib/
    bootstrap.sh           loader: sets RC2_ROOT, sources the chain
    guard_lib.sh           dependency-free, hook-safe: rc2_json_update, rc2_guard_tag,
                           rc2_guard_effective, rc2_mode_rank, rc2_is_frozen, rc2_guard_core_on
    common.sh              colors, rc2_utc, rc2_resolve_rundir, rc2_load_target, flag helpers
                           (rc2_flag_value/hex_in/both_flags/both_accepted/solved), rc2_write_supervisor
    tools_log.sh           logs/tools.jsonl readers (rc2_tl_*)
    env.sh                 .env + SecLists + the single source of guard calibration defaults
    htb.sh                 token/HAR, resolve/spawn, VPN, rc2_htb_owned_init, rc2_flag_watcher/scan
    run.sh                 scaffold, prompts, rc2_run_loop (+ surrender gate), status writer,
                           rc2_claude_oneshot, rc2_negatives, sameness judge + watcher +
                           contradiction signal + commit_freeze, oversee launch
    hook_log.sh            per-call hook: force-log + anti-DoS + P1 accounting/guard (sources guard_lib)
  scripts/                 watch  oversee  guard  report  analyze_run  rag  machine  burp  ...
  doctrine/00..60          the brain (system prompt)
  .claude/agents/          researcher  recon-analyst  exploit-dev  verifier  reverser
  OVERSEER.md JUDGE.md SURRENDER.md   out-of-band reviewer prompts (NOT in the solver's prompt)
```

Out-of-band model calls (`oversee`, sameness judge, surrender gate) all run **outside the repo cwd** via
`rc2_claude_oneshot`, so no repo-local hook / auto-PR Stop hook fires on them.

---

## 8. Extending

- **Change how it thinks** -> edit a `doctrine/*.md`.
- **Add a specialist model/role** -> add `.claude/agents/<name>.md` (frontmatter: name/description/tools/model).
- **Add a guard knob** -> default in `lib/env.sh`, consumed where needed; document in GUIDE 4a + 4.6 here.
- **Add plumbing** -> a function in the right `lib/*.sh`, wired in `hunt`; shared/hook-safe helpers go in
  `guard_lib.sh`, general helpers in `common.sh`.
- **After any large change**: scan for refactors/generalization, explain, and stop for review (the
  established cadence) before implementing. Verify shell logic with stub tests; **model-call features
  (judge/gate) can only be validated by a real run.**

---

## 9. Developer gotchas

- **Same-statement `local` does NOT propagate on this host's bash.** `local a="$1" b="$a/x"` -> `b="/x"`.
  Derive paths from `$1`/positionals directly, or split the `local`. This silently broke the arbiter
  freeze once (fail-open hid it). Scan: `grep -nE '^\s*local .*="\$[a-z_]+/' lib/*.sh scripts/*.sh`.
- **Fail-open hides bugs.** Because the guard swallows errors (`2>/dev/null`), a broken write looks like
  "nothing happened". When something "just doesn't fire", re-run the step without the `2>/dev/null`.
- **auto-PR.** Every file-changing interactive turn auto-branches -> PR -> merges to `main` (a personal
  Stop hook). Expect your edits on `main` after the turn; keep them coherent.
- **The guard is off by default.** `./hunt X` changes nothing; enforcement needs `RC2_GUARD=warn|block`
  or `RC2_GATE=1`. Watcher/oversee/surrender run only when a layer is enabled.
- **Timezones in the journal can drift** (box-time vs UTC); prefer `rc2_utc` and the hook's UTC stamps.

---

## 10. See also

`GUIDE.md` (operate) | `TOOLS.md` (per-tool) | `../CLAUDE.md` (work on the code) | `doctrine/*.md` (the
brain) | `OVERSEER.md` / `JUDGE.md` / `SURRENDER.md` (reviewer prompts).
