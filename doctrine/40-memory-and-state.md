# 40 — Memory & State

Your context window is not your memory. The run directory is. Insane boxes run long
enough that the transcript will be summarized or a fresh instance will take over — so
your real mind lives in three files you keep current **every loop**. A new you must be
able to read them cold and continue with zero loss.

**Your cwd is always the run directory.** The harness starts every Bash command there and resets it
back after each one, so a `cd` inside one command does not carry to the next — the "Shell cwd was
reset to …/runs/<slug>" notice is expected, not an error. Rely on this: do **not** run `pwd`/`cd` to
re-check where you are. Keep everything you produce **inside** this directory, addressed by **relative**
paths (`recon/…`, `loot/…`, `journal.md`). Call a repo tool by its **absolute** path and do not `cd`
out to reach it — e.g. `/home/kali/redcat2/scripts/machine.sh reset <box>`, never
`cd /home/kali/redcat2 && bash scripts/…` (the tools compute their own root and work from any cwd; a
`scripts/` symlink is also present here for convenience). Leaving the run dir — the repo root, `/`,
another run — is only for the rare case a task genuinely requires it; by default, stay home. Keep raw
outputs where they belong (below) and keep the three living files tight — they are *state*, not a log dump.

## The three living files

### `worldmodel.md` — what is TRUE
Only demonstrated facts, each with a one-word provenance. This is the ground truth you
reason from. Structure it so the top is the most load-bearing:

```
# World Model — <machine> (<ip>)
## Access held        <- shells/creds you currently possess, as which principal, on which host
## Privilege map      <- the ladder (10-hunt-loop → orient by the privilege delta). One line per
#                        principal/process/service/container: its privilege (uid, caps, host access,
#                        trust, secrets/actions it holds) and — for YOUR current principal — what you
#                        can and cannot do. Mark which of these run ABOVE you and whether any input you
#                        control reaches them: those are your elevation candidates.
## Credentials        <- user:pass / hashes / keys / tokens, and what each unlocks (verified?)
## Services & versions <- port -> service/version, with the one fact that matters per service
## Hosts & topology    <- the target, any pivots, trust relationships; tag each host's scope (in-scope | conditional | pending | out-of-scope, per 00-prime-directive)
## Notable files/config<- paths, configs, source snippets that matter
## Open questions      <- known unknowns worth resolving
```
Promote a fact here **only after VERIFY**. If it was a guess, it goes in `hypotheses.md`,
not here. Tag each fact's basis — `observed` (you saw it happen or read it directly) vs
`inferred` (deduced from other facts, e.g. "JDK ≥11 because the CORBA class is absent") — so a
fresh instance knows at a glance what rests on direct evidence and what rests on a chain that a
later fact could break.

**Recording a negative** ("X closed / not present / a mock / refuted") needs the same discipline as
a positive, plus two extra tags, because a shallow negative wrongly prunes the search space
(`00` → evidence of absence): write **what test established it** and a **confidence** — e.g.
`CodeBuild = real but no docker.sock [observed · tested: 1 build, privilegedMode untried · conf: low]`
vs `ECS drops all mount/priv fields [observed · tested: host-vol + dockerVolumeConfiguration +
privileged + linuxParameters, 20+ runs · conf: high]`. A `low`-confidence negative is a **re-open
candidate**, not a wall — it is exactly what the blocker re-audit (`00` → Done) and the surrender
gate re-test first. Never let a one-glance dismissal sit here unqualified as if it were proven.

### `hypotheses.md` — what MIGHT break it
The ranked attack board. One block per hypothesis:

```
### H<n>: <one-line claim>            [status: open|testing|confirmed|refuted|frozen]
- preconditions: <what must be true / what you must already hold>
- evidence for:  <facts supporting it>
- evidence against: <facts weakening it>
- confidence: low|med|high   impact: <what it yields>   cost: <to test>
- next experiment: <the concrete test, and what each outcome would prove>
- budget: <attempts used>/<allowed>     # freeze when exhausted
```
Re-rank after every REFLECT. Keep refuted/frozen ones (with the reason) — they stop you
re-walking dead ends and can thaw when a new fact revives a precondition. **The board must
always name the hypothesis you are *currently* pursuing.** When you pivot, set the old block
to `frozen`/`refuted` *with the reason* **and** add the block for the path you're now chasing;
when a flag drops, mark the hypothesis that produced it `confirmed`. A solved box whose board
still shows the dead ends as `testing`/`open` and never names the winning path means the board
was abandoned mid-hunt — keep it live to the end.

### `journal.md` — what you DID and concluded (append-only)
The decision trail. One terse entry per loop: the hypothesis you advanced, the experiment,
the result, the conclusion, the next move. This is your anti-rabbit-hole record and the
thing a fresh instance reads to understand *why* the board looks the way it does. Never
rewrite history here — append. **Timestamp every entry in UTC** (`date -u +%FT%TZ`) so the
journal, the tool logs, and the retrospectives all share one clock.

### `ledger.json` — the machine-readable mirror (the harness enforces on THIS)

`hypotheses.md` is the human view; `ledger.json` is the same state in a form the harness can read and
act on. They must agree — when they drift, **`ledger.json` is authoritative for automation**. Update it
**every loop, right after you update the board**. It is small and it is *yours* (your "intent"). The
harness keeps a **separate** `logs/accounting.json` of counters — how many times each hypothesis was
tried, whether progress is moving, override spend — that **you must never write**; leave it to the hook.
Keeping your intent (`ledger.json`) and the hook's accounting in different files is deliberate: a
malformed hand-edit of yours can never corrupt the counters the harness relies on.

Shape (create it if missing — `H<n>` keys mirror the board exactly):
```json
{
  "schema": 1,
  "updated_utc": "<date -u +%FT%TZ>",
  "current_hypothesis": "H3",
  "hypotheses": {
    "H3": { "claim": "<one line, same as the board>", "target": "<service/host/primitive it attacks>",
            "status": "open|testing|confirmed|refuted|frozen", "budget_max": 8,
            "freeze": { "frozen": false, "confidence": "low|med|high", "reason": "",
                        "by": "self", "resumable": true, "at": "" } }
  },
  "confirmed_path": [
    { "h": "H2", "summary": "worker RCE via unsafe yaml.load -> shell as worker",
      "how": "SSRF octal-IP bypass -> IMDS -> nimbus-web-role creds -> aws sqs send-message yaml.load os.system gadget (non-blocking setsid)",
      "yields": "shell as worker in tmux <tmux_base>_main (verify: id -> uid=1000)", "at": "<utc>" }
  ],
  "override": null
}
```
`override` is normally `null`. Set it to `{ "hypothesis": "H<n>", "reason": "<why this path, not a
switch>", "nonce": "<unique string>" }` **only** to push past a guard block once (see
`10-hunt-loop.md` → the guard); the harness honours it a single time, then records the nonce as spent.
A new block needs a fresh `nonce`; repeated overrides on the same hypothesis escalate.
Rules: **(1)** `current_hypothesis` always names the block you are pursuing *right now* — the hook
counts your experiments against it. **(2)** On a VERIFY-confirmed flag or step, append one
`confirmed_path` entry: a one-line `summary` (copied **live** into `writeup.md`, so the solve chain
builds as you go, not at the end), the **`how`** — the method at a level you could re-execute (the
primitive, the vector, the knobs that matter — not a command transcript), and the **`yields`** — the
observable signal that proves the step re-succeeded (e.g. `id -> uid=1000`). This is a plan a *reasoning*
session **re-walks**, not a frozen script: the live instance differs every spawn (rotated creds, new
container IDs, a fresh flag), so the durable asset is the *method*, re-executed with judgment and
re-verified. You MAY drop a helper script in `exploit/` for a purely mechanical sub-step (e.g. re-pulling
IMDS creds) and mention it in `how`, but treat it as an adaptable aid, **never** as the replay mechanism —
redcat2 is not a playbook runner (`00`/README). **(3)** When you
freeze a hypothesis, set `freeze.frozen=true` with an **honest** `confidence` and a one-line `reason`:
a `low`/`med` freeze may be thawed later if a new fact revives it, a `high` one should not be reopened
without strong new evidence. `by` is `self` for your own freezes. A freeze with **`by: arbiter`** was
set by the independent judge because it ruled the hypothesis a rabbit hole; it is mirrored here for
your view but held authoritatively by the harness, so flipping `frozen` back to `false` yourself does
**nothing** — treat it as closed and move on, or, only if you are genuinely sure it is wrong, spend a
one-shot `override`. **Never** record here — or in `confirmed_path` — a win that VERIFY has not
confirmed (the same evidence discipline as `worldmodel.md`).

## Raw artifacts (not memory — evidence)

Keep full, unsummarized output on disk, organized so you can find it again:

```
recon/              network + surface scans (full nmap, etc.)
enum/<service>/      per-service deep enumeration (enum/web/, enum/smb/, ...)
loot/                credentials_found.txt + hashes/ keys/ tickets/ files/
exploit/             PoCs, payloads, adapted exploit code
reversing/<binary>/  IDA exports (pseudo.c, strings.txt, imports) + FINDINGS.md (from reverser)
tools/               scripts YOU wrote (one-line purpose comment on top)
bin/                 downloaded third-party binaries (untrusted; read before run)
research/            vetted briefs from the researcher sub-agent, with source URLs
logs/                tools.jsonl, raw/, conv.jsonl (auto by the hook); phases.log (YOU append it)
notes/               scratch reasoning, draft exploit math, anything else
flags.txt            user=<hex> / root=<hex> as captured
```
Rule: **never re-run a command whose output already exists** — read the file. The hook
logs every tool call to `logs/`, so before repeating an expensive scan, check whether you
(or a prior session) already ran it.

`status.md` and `failure_analysis.*` are **auto-generated** (a periodic snapshotter + an on-exit
classifier) — read-only; your own record is `journal.md`. `writeup.md` is also assembled on exit by
`report.sh` from your living files — an emoji banner with the flags, the solve chain from
`journal.md`, the verified facts from `worldmodel.md`, the tools you wrote, and the metrics block —
so **the quality of the write-up is the quality of `worldmodel.md` + `journal.md`.** You MAY write a
curated narrative *above* the `<!-- WRITEUP -->` block; report.sh preserves everything above its
markers and only refreshes between them. If you draw any banner or diagram anywhere, use **emoji**
(project style), not ASCII box-drawing characters.

## Flags

The instant you read a real flag — **before your next action, never batched to the end of the
run** — append it to `flags.txt` as `user=<hex>` or `root=<hex>` and emit `<FLAG><hex></FLAG>` in
your output. A background watcher auto-submits flags to the lab API (you never call submit
yourself) and **skips any user/root it has already submitted** (`logs/.submitted`); it also
auto-records a flag it sees you read from `user.txt`/`root.txt`, but that is only a backstop (up to
`FLAG_INTERVAL` late) — you still record it the moment you see it.

## Resume

A fresh instance (or you, after a context reset) resumes by reading, in order: the **top** of
`worldmodel.md` → the **ranked** `hypotheses.md` → the **tail** of `journal.md` → `flags.txt`.
That is enough to know what's held, what's next, and what's already ruled out — **do not
re-ingest everything**, and do not re-run enumeration whose output is already on disk.

**Replay your confirmed path — re-walk it, don't re-derive it.** The access you already won is recorded as
`confirmed_path` (rule 2: `summary` + `how` + `yields`). On resume, **re-establish state by re-executing
those steps yourself** against the live target — follow each `how` with your own tools, adapt to the
current instance (fresh creds/IDs/flags), and confirm each `yields` — rather than re-reasoning the whole
foothold from the journal. This is a reasoning **re-walk**, not a script run: you adapt the non-deterministic
parts (a rotated token, a new container id) as you go. Re-walking a proven chain is faster, cheaper on
context, and more reliable than rediscovery; re-deriving an already-confirmed step from scratch is a
mistake. Only when a step genuinely fails do you re-derive that one step (and update its `how`). Then pick
up from the frontier (the first not-yet-confirmed hypothesis). Keep the
three living files **tight** (state, not a log dump — raw output belongs in `loot/ enum/
research/`, never pasted into memory); a bloated journal makes every resume expensive and is a
fast road to context overflow. Keeping them current *and lean* is not bookkeeping — it is what
lets the hunt survive longer than any single context window, which is the whole game on
Insane-tier targets.
