# 10 — The Hunt Loop

This is your operating cycle. You run it continuously until both flags are verified.
It is a disciplined version of observe → orient → decide → act, specialized for
breaking a machine you've never seen. Each pass is small: one hypothesis, one
experiment, one honest update. Many small honest passes beat one big hopeful leap.

```
            ┌─────────────────────────────────────────────┐
            ▼                                             │
   ORIENT ─► RESEARCH? ─► EXPERIMENT ─► OBSERVE ─► VERIFY ─► REFLECT
   (pick     (learn the   (smallest    (capture   (prove    (update model,
    the best  unknown      test of the  evidence)  it truly  re-rank, detect
    hypothesis first)      hypothesis)             happened)  rabbit holes)
```

## 1. ORIENT

Read the top of `worldmodel.md`, `hypotheses.md`, and the tail of `journal.md`. Then
state, in one or two sentences in the journal, **the single thing you are advancing this
pass and why**. Choose it by expected value, not by habit:

> score ≈ (confidence it's real) × (impact if it works) ÷ (cost to test)

- **Impact** = how much closer it gets you (new access > new credential > new surface >
  new fact).
- **Cost** = time, noise, and risk of corrupting state on the target.
- Early on, the whole board is unknown, so the highest-impact move is almost always
  **widening what you can see** (broad+deep enumeration) rather than attacking. You
  cannot form good hypotheses about surface you haven't observed. Enumerate until the
  surface stops yielding new facts, *then* attack the richest seam.

If no hypothesis has meaningful confidence, your ORIENT output is "I lack information"
and the pass becomes an enumeration/observation pass, not an attack.

## 2. RESEARCH? (conditional, but frequent on Insane)

Before acting, ask: *does this experiment depend on anything I do not understand cold?*
A service or framework you can't fully reason about, a version with unknown known-bugs,
a CVE id, an unfamiliar error string, a protocol quirk, an exploit you'd run. If yes,
**research it first** (`doctrine/20-research-and-dorking.md`), usually by delegating to
the `researcher` sub-agent. Come back with a concrete, testable plan and, where relevant,
exploit code you have *read and understood*. On Insane boxes this branch fires often —
treat "I should look this up" as a strength, not a delay.

## 3. EXPERIMENT

Design the **minimal** action that will generate evidence for or against the current
hypothesis. Good experiments are cheap, information-dense, and as reversible as possible.
Prefer a probe that *distinguishes* between competing hypotheses over one that merely
confirms a hope. Run it. Long or interactive actions go through tmux
(`doctrine/30-interactive-and-tools.md`); install any missing tool on the fly.

Write down, *before* you look at the output, what each possible result would mean. This
is what stops you from rationalizing whatever comes back.

## 4. OBSERVE

Capture the **full, raw** output to the right file under the run dir — never work from a
mental summary, never discard output you haven't read. If the output is large, hand it to
`recon-analyst` to distill into facts, but keep the raw. Promote only *demonstrated* facts
into `worldmodel.md`, each with a one-word provenance (how you know it).

## 5. VERIFY

Separate "the command executed" from "the objective was achieved." For any claim that
changes your strategy, confirm it independently:

- *Shell/access?* Run an identity + context check (`id`, `whoami /all`, `hostname`,
  network, who else is here) — don't assume a payload landed because the listener moved.
- *Credential?* Authenticate with it against a second service, or re-use it; a hash that
  cracks is not a cred until it logs in somewhere.
- *Flag?* Confirm it's the real artifact (read from `user.txt`/`root.txt` on the target),
  not an echo, a decoy, or a hash in unrelated output.
- *High-stakes or destructive action?* Have the `verifier` sub-agent red-team your plan
  **before** you run it.

If verification fails, the hypothesis is *not* confirmed no matter how much you wanted it.
Record the gap and continue.

## 6. REFLECT & RE-RANK

Update `hypotheses.md`: promote (confirmed), demote (weakened), refute (disproved), and
**spawn new hypotheses** from the facts you just learned — this is where Insane chains get
built, one proven rung at a time. Re-score the board.

**Rabbit-hole discipline (non-negotiable):**
- Each open hypothesis carries an **evidence budget** — a count of attempts allowed with
  *no movement in evidence* (default ~3-4 experiments or ~8 actions). On exceeding it,
  **freeze** the hypothesis: write in `journal.md` exactly what you tried, why it didn't
  move, and what new information would revive it. Then switch to the next-ranked hypothesis.
- Freezing is not failure — it is how you stay solvent. A frozen hypothesis can thaw the
  moment a later fact revives its preconditions.
- **Zoom-out trigger:** whenever you freeze a hypothesis, or every ~10 actions, re-read
  `worldmodel.md` top to bottom and ask: *what surface or fact am I not using? what would
  someone who just arrived look at first?* The answer is often a seam you walked past while
  tunnelling.

**External supervisor (`supervisor.md`):** an operator-level reviewer may run alongside you
and write `supervisor.md` in the run dir when it sees you drifting. At the start of each pass,
check its first line `SUPERVISOR_TICK: N`. Act on it **only when N is newer** than the tick you
last applied (record the applied tick in `journal.md` so you don't re-apply it). When the tick
is new: stop your current action, do a quick self-review (re-read `worldmodel.md` + recent
evidence), then follow its STOP / DO NEXT as top priority — its redirects **override** your own
"dead end" conclusions. You never edit `supervisor.md`; the reviewer owns it. If no such file
exists, ignore this — you are not being supervised and proceed normally.

## Phase as a side effect

"Recon", "foothold", "user", "privesc", "pivot", "root" are **labels you apply in
hindsight** to describe what your evidence now supports — not a queue. You are in "privesc"
when your world model says you hold a shell and your best hypotheses are about escalating;
you drop back to "enumeration" the instant you realize you can't see enough to escalate.
Let the evidence set the phase. Append `logs/phases.log` with a timestamped line whenever
the phase label genuinely changes, so the run can be timed later.
