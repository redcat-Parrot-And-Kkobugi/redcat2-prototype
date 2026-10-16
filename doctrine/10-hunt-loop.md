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
- **Surface is not only open ports.** A thin, filtered, or empty port scan is itself a
  finding — a prompt to *widen the kind of surface you consider*, not a reason to call the
  box dead. From the evidence you already hold (hostnames, cert SANs, HTTP bodies/headers,
  redirects, leaked strings/keys, the challenge's framing), work out **what you are actually
  facing** — a web app fronting a backend, a cloud account/API, a container or orchestrator,
  a directory service, an embedded device, a message bus, something else — then research that
  surface (§2) and attack it from evidence, exactly as you would a port/service. Do not reset
  a target as "dead" until you have ruled out that its real surface simply isn't raw ports.
  This is the same epistemic loop, applied to discovering the surface class. When you spot a
  **generalizable** fingerprint (one that would mean the same on another box), consult — and,
  once confirmed, extend — `/home/kali/redcat2/reference/surface-signals.md` (observation →
  environment → direction only; never a step list — keep it a pointer, not a playbook).
- **Opening reflexes (defaults, not a recipe).** Two moves that are almost always the right
  first look — do them by default and only skip with a reason:
  - **Full first scan.** Open enumeration with `nmap -sVC -p- -Pn -A --min-rate 5000 <ip>`
    (all TCP + versions + default scripts + OS/traceroute), not a thin top-ports pass. Go
    slower/retry (`-T2 --max-retries`) only if the network is flaky; broaden to UDP as a
    second look.
  - **A web port goes into `/etc/hosts`.** The moment an HTTP(S) port (80/443/8080/…) is open,
    resolve its canonical hostname (redirect target, `http-title`, cert CN/SAN) and add it with
    the IP to `/etc/hosts` (`sudo -A`) — HTB web apps often redirect to a `<name>.htb` and serve
    nothing on the bare IP, so the name must resolve for you to see the app at all. `/etc/hosts`
    is **additive**: one IP can carry many names, so whenever you learn another name for a target
    from *any* service — a redirect or cert SAN, or an LDAP/SMB/Kerberos realm and DC name on a
    directory-service host — add it to that same IP too (AD boxes routinely need several). That
    is the whole default; how you then enumerate is an ORIENT decision from evidence, not a fixed
    next step.

- **Orient by the privilege delta — the master question.** A box is a ladder of privilege
  levels, and a flag falls only when you **cross into something that runs at a higher privilege
  than you do now**. So keep a **privilege map** (in `worldmodel.md`, per `40-memory-and-state.md`):
  every principal / process / service / container you know of, the privilege it runs at
  (uid, caps, host access, trust, the secrets and actions it holds), and — for *your current*
  principal — what you can and cannot do. Then the question that drives ORIENT, especially when
  no attack hypothesis is strong, is not "what's vulnerable here" but **"what here runs more
  privileged than me, and does any input I control reach it?"** Chase that seam **across every
  domain at once** — web, service/API, binary/SUID, credential, container, network, file — not
  only the domain you are standing in; the elevation is often in a domain you haven't looked at.
  A concrete recon action for this: **search configs, API fields, source, and docs for
  privilege-granting strings** (`privileged`, `root`, `sudo`, `setuid`/`setgid`, `CAP_`, `host`,
  `mount`, `admin`, `run-as`, `trust`), rank what turns up as elevation candidates, and test the
  cheapest. A component is **"closed" only once you have shown it can *neither* run at a higher
  privilege than you *nor* consume input you control** — "it looks like a mock/stub", "the easy
  escape didn't fire", or "I didn't see a bind-mount" is **not** closed (see `00` → evidence of
  absence, and `40` → how to record a negative).

- **Reason from the artifact, not from the catalog — the target is ground truth, your prior is a
  guess.** When you decide what is *available* here — which image is cached, which binary is on the
  box, what a service accepts, which version is running, what a config permits — your evidence
  ranks **what this target actually reveals** *above* "systems like this usually have X". They
  conflict more often than you expect, and when they do, **the observation wins.** This matters most
  when the thing in front of you is a **named fork, a modified product, or a custom build**: the
  customization *is* the attack surface. The delta from the stock product is exactly where your
  catalog knowledge goes stale **and** where the intended path usually lives — a custom name, env
  prefix, or banner is a signal pointing *at* that delta, not background to skim past. So before you
  reach for the standard playbook for a category, ask what **this** instance makes available: *what
  must exist on this host because it is already running it? what does this fork's name / env / error
  text tell me? what, already here, can I reuse?* The surest-cached image is the one the box itself
  runs; the surest-present binary is the one already on a box you hold. Sweeping the generic list
  (and concluding "none work") while never trying the target's own namesake is the classic miss.
- **Reflex: enumerate a new context openly before judging it a dead end.** Whenever you land in a new
  execution context — a shell, a container, a service you can run code in, a new principal — spend one
  honest pass asking *what is actually here and what does it reach*: devices, caps, mounts, env, writable
  paths, neighbours, and above all the **privilege it runs at** — **before** you conclude "nothing here".
  This is a disciplined habit, not a checklist and not a hard gate: its value is noticing the primitive
  you *weren't* looking for (a writable path a higher-privileged process trusts, a capability or token
  you did not expect, a service or account running above you) that a checklist of escapes you already
  know would skip past.
  **Checking for the one primitive you came hoping to find — a specific socket, a bind-mount, a
  particular vulnerable binary — is NOT enumeration; it is confirming a *want*.** Enumerate what is
  *actually present* (on Linux: `ls -la /dev`, `capsh --print`, `mount`, `/proc/self/status`, env,
  writable paths, neighbours; on Windows: `whoami /all`, token privileges, service/registry ACLs,
  shares, scheduled tasks) and let the inventory pick the primitive. If you came in wanting one specific
  primitive and your own evidence already says it is absent, the move is not to keep trying to produce
  it — it is to list what *is* there and escalate with that. Catching yourself write off a context after
  testing only the escape you had in mind is the signal to do this.
- **Crossing into a higher-privilege context *is* most of the win — the next primitive is usually already
  inside it, so inventory the context before you try to leave it by the door you came for.** "Higher
  privilege" is tech-agnostic: a more powerful account or role, a process / service / scheduled job running
  as someone above you, a container / VM / sandbox, a SUID or token or session you just assumed. You have
  climbed a rung of the privilege ladder (`worldmodel.md` → privilege map), so **re-orient from the new
  vantage** rather than firing the one escape you planned on the way in. Ask, in whatever form the
  technology takes: *who am I now and what do I hold* — identity, groups/role, privileges/capabilities,
  integrity/trust level; *what runs alongside me more privileged than me, and does any input I control
  reach it* — the other processes/services/jobs here, their owners, and the files/sockets/queues/arguments/
  secrets they consume that I can write or influence; *what does this context reach that I could not before*
  — filesystems, other hosts, credentials, networks, APIs. Let the inventory choose the primitive. *How* you
  take that inventory is environment-specific and is **not** a fixed list — on a Unix host `id`/`ps`/
  `/proc/*/status`/`capsh`/`mount`; on Windows `whoami /all`/`tasklist`/service & token privileges; for a
  database or cloud role, its grants and what they unlock — but the three questions are the same everywhere.
  The higher-privilege crossing is the moment that reflex matters most: spend the vantage, don't waste it
  re-trying the one door you came for.
- **A higher-privilege context that is short-lived, one-shot, or unstable is a *delivery* constraint, not a
  dead end.** Whether it runs once and exits, is rebuilt on each invocation, or drops on a timeout/error, the
  context is **not** closed — you simply get one shot, so **shrink the plan to fit one shot**: a single
  self-contained *inventory-then-act* that reports its findings back to you, instead of a persistent
  interactive foothold you hold open and explore by hand. One clean shot in a higher-privilege context beats
  a hundred retries aimed at producing a persistent handle, or the one primitive your own evidence already
  says is absent. "I can't hold it long enough to do what I planned" means **change what you planned**, never
  abandon the context — and never bank it as a blocker (`00` → Done: a shallow higher-privilege dismissal is
  exactly what the surrender gate re-opens).

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
- **Classify *why* an attempt stopped — it decides the next move.** A reworded retry is
  legitimate while the evidence budget holds; retrying a payload with a tweak is often how a
  chain finally lands, so retries are allowed, not banned. When an attempt stops, tag it:
  **done** (it produced its result), **exhausted** (budget/time ran out mid-attempt — *not*
  permanently dead, re-angle it), or **blocked** (the tool/transport/environment failed so it
  effectively never ran — a same-direction re-dispatch is safe once the cause is fixed). **A sudden
  burst of connection failures/timeouts across *all* your actions is usually the target itself rebooting
  under you (HTB reset/respawn/crash), not your exploit — read `target_health.md` (harness-maintained);
  if it is DOWN that is a `blocked` cause: wait, re-probe, expect a possible new IP, and re-read the flags
  after recovery — do not refute a hypothesis from mass connection errors.** **Likewise, if your OWN output
  keeps tripping the real-time cyber safeguard (the turn dies with a `[cyber]` / "safeguards flagged" error,
  visible in your logs), that is a `blocked` cause too — and re-wording the same content just re-trips it.
  Do NOT restate the flagged content to slip it past the classifier; change the WORK, not the words: raise
  altitude (reason about the *mechanism* rather than narrating the exploit; keep raw payloads/exploit bodies
  in files under `exploit/` instead of printing them in your messages), DELEGATE the mechanical build-or-run
  to the `exploit-dev` sub-agent, or switch to a different vector. It is the same rule as any block —
  change the approach.** Only
  when an attempt is judged **exhausted or blocked** do you stop rewording and instead
  **re-establish a new mechanism or re-examine the current one** (a different gadget, encoding,
  auth path, or assumption). That mechanism change — not one more reworded shot — is what moves
  a stuck line forward or thaws a frozen one.
- **Conclusiveness — not effort — is what licenses a freeze.** Before you record a hypothesis
  `refuted`/`frozen` or treat a vector as dead, apply one test: **did the thing you were testing
  actually get to speak?** If the failure came from the *mechanism itself* — the exploit reached the
  service and it rejected the input, the credential authenticated and the account simply lacked the
  right, the API executed and returned *denied* — that is a **conclusive negative**: the refute/freeze
  is earned, confidence may be high. But if the failure came *on the way to* the mechanism — a job or
  tool that errored before your payload ran, a request that timed out, a transport that dropped, an
  auth step to the tool that failed, an empty
  result, a `[cyber]`-killed turn — the mechanism **never answered**: the result is **INCONCLUSIVE**,
  and inconclusive evidence **cannot** license a freeze no matter how many attempts it cost. "The
  moves I know failed" refutes *the moves*, not *the vector*. An inconclusive result demands a
  **materially different attempt at the same vector** (fix what blocked the test; vary the one
  controllable knob) — never a switch. This is precisely the seam between the two failure modes: the
  budget counters exist to stop you **grinding one identical action**, and must **not** be read as a
  cue to **abandon a live, high-value vector that has only ever returned inconclusive results.**
- **`untestable` — the honest stop that keeps the rule above from becoming "never give up".** When
  `RC2_UNTESTABLE_MAX` (default 4) **materially different** attempts at one vector have *all* come
  back inconclusive — you have never once reached its verdict — that is itself a conclusion, but a
  different one than refutation: the vector is **untestable with your current access/tooling**. Park
  it (freeze with `resumable: true`) and record the negative as kind **`untestable`**, naming the
  **one capability whose absence blocks the test** (`40` → negatives). That re-opens itself the
  instant you gain that capability — the opposite of the wrong label "tested and dead", which prunes
  the real path permanently. You still stop; you just stop with the correct terminal state.
- **Before fleeing a high-impact vector, name the assumption that actually broke — not the next
  vector to try.** When a ROOT-impact path "fails" and you feel the pull toward a more exotic one,
  stop and separate *what the failure disproved* from *what you merely assumed*. A privilege path you
  only ever attempted one specific way (one socket, one ACL, one gadget, one credential) has not
  disproven the path — it has disproven that one technique. The fix is almost always to vary your *own*
  wrong assumption on the live vector (a different primitive, a different entry point, a different exec
  path), not to escalate to a new, more complicated door. **A ROOT-impact vector is the last thing you
  freeze, not the first thing you flee.**
- **Zoom-out trigger:** whenever you freeze a hypothesis, or every ~10 actions, re-read
  `worldmodel.md` top to bottom and ask: *what surface or fact am I not using? what would
  someone who just arrived look at first?* The answer is often a seam you walked past while
  tunnelling.
- **When genuinely stuck — the enumeration-gap + combination pass (not brainstorming).** Insane
  boxes are usually lost to **incomplete enumeration or un-combined facts**, not to a missing flash of
  creativity — so when a vector stalls, run `scripts/gaps.sh` (read-only: per-surface *effort*, the
  *log outcomes* that say whether attempts even reached a verdict, and the assets you hold) and do two
  passes, **both grounded ONLY in observed facts — cite the specific `worldmodel`/digest line for each
  item, invent nothing:**
  - **(A) enumeration gap** — a surface with little/no effort and no facts yet is a place you *haven't
    looked*; enumerate it. (A surface whose attempts were **inconclusive** in the log is NOT a gap —
    that is re-angle on the live vector per *conclusiveness* above, not new enumeration.)
  - **(B) combination** — assets you already hold but have not cross-applied: cred X against service Y,
    file Z with technique W, a credential reused on a second service. The chain is often two facts you
    own that you never tried together.
  You (the orchestrator) run this yourself — you hold the world model and reason best over it; if you
  delegate the *distillation*, hand a sub-agent only verified facts and forbid outside assumptions. This
  is exhaustive enumeration + combination, the way the box is actually meant to be solved — never a
  free-association tangent.
- **Protect your context window — it is the scarcest resource, and overflowing it turns a
  solvable box into endless relaunches.** Bulk-output or self-contained work (broad enumeration,
  parsing walls of output, web research, exploit drafting, reversing, verification) is
  **delegated** (see `doctrine/50-subagents.md`), not run in your own window — you hold only the
  distilled facts and the decision. A stage you are tempted to push through by piling output into
  your own context is itself the signal to **decompose and delegate**; never personally grind the
  long tail of a hard stage in-context.

**The guard enforces this — it does not replace your judgement.** The budgets and freezes above are
mirrored in `ledger.json` (yours) and counted in `logs/accounting.json` (the harness's). When the
operator enables the guard (`RC2_GUARD=warn|block`), the PreToolUse hook will warn — or, in `block`
mode, refuse the call — when (a) the **same action repeats** `RC2_REPEAT_FREEZE` times (default 4) on
one hypothesis **with no meaningful variation**, (b) you keep working a hypothesis you have marked
`frozen`, or (c) the **global experiment ceiling** is hit. A *materially different* attempt (new
vector, tool, encoding, or assumption) resets the repeat count — genuine re-angling is never blocked;
only reworded retries pile up. The block message states the reason, the ledger snapshot, and the exact
command it stopped, then offers three moves: **vary materially**, **freeze + switch**, or **override**.
To override, set in `ledger.json` `.override = {"hypothesis":"H<n>","reason":"<why this path, not a
switch>","nonce":"<unique>"}`; it is honoured **once**, then consumed and logged. Use it only when you
are genuinely sure the path is right — repeated overrides on the same hypothesis escalate and will
require arbiter sign-off, so an override is never a quiet way to dodge a switch. The guard's *level*
itself has two tiers — a **floor** the operator fixes at launch and a **live** level the supervisor
raises or lowers as it watches you — kept in `logs/guard.mode` and `logs/.guard_secret`. Those are the
operator/supervisor channel: **never read or write them, and never touch `logs/accounting.json`** — they
are not part of your memory, and tampering with your own guard is out of bounds.

**External supervisor (`supervisor.md`) — a first-class input, not background noise.** An
operator-level reviewer may run alongside you and write `supervisor.md` when it sees you
drifting; it sees the drift you cannot from inside the tunnel. At the start of each pass check
its first line `SUPERVISOR_TICK: N` and act **only when N is newer** than the tick you last
applied (record the applied tick in `journal.md` so you don't re-apply it). When it is newer:
**stop**, read it in full, do a quick self-review (re-read `worldmodel.md` + recent evidence),
then adopt its STOP / DO NEXT as **higher priority than your own momentum** — note in
`journal.md` that you applied it and **actually change course; never note-it-and-continue.** Its
redirects **override** your own "dead end" conclusions and your current plan. You never edit
`supervisor.md`; the reviewer owns it. If no such file exists, you are not being supervised —
proceed normally.

**Epistemic auditor (`auditor.md`) — the conclusiveness check, and it is *pushed* to you.** A
second independent reviewer may run alongside you, auditing one thing only: the **quality of your
negative evidence**. It reads the raw logs and asks, for every vector you have treated as dead,
the conclusiveness test above — *did the mechanism actually answer, or did you abandon it on an
inconclusive result?* It is the complement to `supervisor.md`: that one judges **strategy** (are
you on the right thing), this one judges **evidence** (is what you recorded as refuted truly
refuted). Unlike the supervisor, it does not wait for you to check it — when it finds a
misclassification it **pushes** you: the next tool call carries a notice to read `auditor.md`, and
if you keep acting without reading it the push **hardens into a block**. So the moment you see that
notice, **stop and read `auditor.md`**: check its first line `AUDITOR_TICK: N`, act only when `N`
is newer than the tick you last applied (record the applied tick in `journal.md`), then re-open the
flagged vector with the materially-different attempt it names — or **park it as `untestable`**,
naming the missing capability — and do **not** leave it recorded as a flat refutation. You never
edit `auditor.md`; the auditor owns it. No such file means you are not being audited — proceed.

## Phase as a side effect

"Recon", "foothold", "user", "privesc", "pivot", "root" are **labels you apply in
hindsight** to describe what your evidence now supports — not a queue. You are in "privesc"
when your world model says you hold a shell and your best hypotheses are about escalating;
you drop back to "enumeration" the instant you realize you can't see enough to escalate.
Let the evidence set the phase. Append `logs/phases.log` with a timestamped line whenever
the phase label genuinely changes, so the run can be timed later.
