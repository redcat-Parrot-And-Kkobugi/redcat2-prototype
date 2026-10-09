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

## Quick start

```bash
cp .env.example .env            # fill CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)
./hunt Blizzard                 # HTB name -> API resolves/spawns; opus orchestrator
./hunt 10.10.11.42 opus "notes" # raw IP (IP-only mode if no HTB token)
```

**HTB token is hands-off.** Save a devtools HAR from a logged-in `app.hackthebox.com`
(Network tab → Save all as HAR) into `har/`. When the labs token is missing or expired,
`./hunt` finds the newest HAR, extracts and verifies the `aud:6` bearer, and writes it
back — then resolves the machine (OS/difficulty/IP), spawns it if needed, and auto-submits
captured flags via the API. The whole HAR → token → spawn → submit pipeline is bundled.

Re-run the same target to **resume** — state lives on disk, not in the transcript.

## How it thinks — the Hunt Loop

```
  ┌────────────────────────────────────────────────────────────────────────┐
  │  1. ORIENT     pick the best hypothesis (confidence × impact ÷ cost)   │
  │  2. RESEARCH?  learn whatever you don't know cold, before acting       │
  │  3. EXPERIMENT run the smallest test that moves that hypothesis        │
  │  4. OBSERVE    capture the full, raw evidence                          │
  │  5. VERIFY     prove it truly happened (independent check)             │
  │  6. REFLECT    update the board, re-rank, freeze dead ends             │
  └───────────────────────────────── loop until user.txt + root.txt ◄──────┘
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
| **Team** | `.claude/agents/*.md` | Multi-model sub-agents: `researcher` (sonnet), `recon-analyst` (haiku), `exploit-dev` (opus), `verifier` (opus). One file each; add a specialist by adding a file. |
| **Memory** | `runs/<slug>/` | Three living files — `worldmodel.md` (verified facts), `hypotheses.md` (attack board), `journal.md` (decision trail) — plus raw evidence dirs. Survives context resets. |
| **Plumbing** | `hunt`, `lib/`, `scripts/`, `tools/` | Launcher, env/HTB/VPN bootstrap, bundled HTB API client, HAR token extractor, tool-logging hook, flag auto-submit. |

## Design choices

- **Research is first-class.** The agent is expected to hit the live internet — CVEs, vendor
  advisories, exploit code, Google dorks — and to *read exploit code before running it*. See
  [`doctrine/20-research-and-dorking.md`](doctrine/20-research-and-dorking.md).
- **Multiple models by role.** Cheap bulk parsing on haiku, research on sonnet, hard
  reasoning and verification on opus — assigned per sub-agent, tunable per box.
- **tmux over herdr.** [herdr.dev](https://herdr.dev/) was evaluated; its agent-coordination
  overlaps Claude Code's native sub-agents, so tmux (proven for holding interactive sessions)
  was kept and herdr left as a future multi-machine option. Rationale in `CLAUDE.md`.
- **Standalone.** No runtime dependency on any sibling project — the HTB API client, HAR
  token extractor, and log renderer are vendored into this tree, and it reads only its own
  `.env`. The design lineage is redcat1, but deleting redcat1 does not affect redcat2. The
  one external resource is the shared SecLists wordlist tree at `$SECLISTS`.

## Extending

- **Change behavior** → edit a `doctrine/*.md` file.
- **Add a specialist model/role** → add a `.claude/agents/<name>.md`.
- **Add plumbing** (reporting, a supervisor, a different lab API) → add to `lib/` and wire in
  `hunt`. Nothing about the loop assumes HTB specifically beyond `lib/bootstrap.sh`.

## Status

Scaffold complete and syntax-checked. Not yet run end to end against a live box — the first
real hunt is the acceptance test. Expect to tune doctrine wording and sub-agent model
assignments after watching one run.
