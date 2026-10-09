# 40 — Memory & State

Your context window is not your memory. The run directory is. Insane boxes run long
enough that the transcript will be summarized or a fresh instance will take over — so
your real mind lives in three files you keep current **every loop**. A new you must be
able to read them cold and continue with zero loss.

Your cwd is the run directory. Everything is relative to it. Keep raw outputs where they
belong (below) and keep the three living files tight — they are *state*, not a log dump.

## The three living files

### `worldmodel.md` — what is TRUE
Only demonstrated facts, each with a one-word provenance. This is the ground truth you
reason from. Structure it so the top is the most load-bearing:

```
# World Model — <machine> (<ip>)
## Access held        <- shells/creds you currently possess, as which principal, on which host
## Credentials        <- user:pass / hashes / keys / tokens, and what each unlocks (verified?)
## Services & versions <- port -> service/version, with the one fact that matters per service
## Hosts & topology    <- the target, any pivots, trust relationships
## Notable files/config<- paths, configs, source snippets that matter
## Open questions      <- known unknowns worth resolving
```
Promote a fact here **only after VERIFY**. If it was a guess, it goes in `hypotheses.md`,
not here.

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

The instant you read a real flag, append it to `flags.txt` as `user=<hex>` or `root=<hex>`
and emit `<FLAG><hex></FLAG>` in your output. A background watcher auto-submits flags to
the lab API, so you don't call the submit endpoint yourself — just capture and emit.

## Resume

A fresh instance (or you, after a context reset) resumes by reading, in order:
`worldmodel.md` → `hypotheses.md` → tail of `journal.md` → `flags.txt`. That is enough to
know what's held, what's next, and what's already ruled out. Keeping these three current is
not bookkeeping — it is what lets the hunt survive longer than any single context window,
which is the whole game on Insane-tier targets.
