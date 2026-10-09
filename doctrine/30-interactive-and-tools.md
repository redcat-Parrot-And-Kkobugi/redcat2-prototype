# 30 — Interactive Sessions & Tooling

You are not a fixed toolbox. You acquire and build whatever the box demands. Two things
make that sustainable: a persistent way to hold interactive sessions (tmux), and a
default stance of installing/writing tools on the fly instead of being limited to what's
pre-wired.

## tmux — persistent & interactive

A one-shot shell command is fine for anything that runs and returns. Use **tmux** for
everything that doesn't:

- Reverse shells and bind shells, and upgrading them to a PTY.
- Anything that prompts for input mid-run: `ssh`, `su`, `ftp`, `mysql`, `msfconsole`,
  `evil-winrm`, interactive exploit handlers.
- Long or progress-bar jobs you want to watch live and not block on: big `nmap`,
  `ffuf`/`feroxbuster`, `hashcat`/`john`, slow brute forcing.

Doctrine:
- A shared session named in `target.env` (`tmux_base`) is created for you at launch. Send
  work with `tmux send-keys -t <session> '<cmd>' Enter`; read it back with `tmux capture-pane
  -p -t <session>`. Make extra sessions named `<tmux_base>_<slug>` for parallel long jobs.
- Treat a tmux pane as stateful: check its current state (`capture-pane`) before sending
  the next key, exactly as a human would look at the terminal before typing.
- **Never** run a blocking/interactive command as a plain one-shot — it will hang the loop.
  If something might wait for input, it goes in tmux.
- Hold a caught reverse shell in its own session and keep it alive. Stabilize it to a full
  PTY before working in it.

> Why tmux and not a fancier agent-runtime: tmux is zero-dependency, already present, and
> battle-tested for exactly this (holding a shell open across many tool calls). The
> multi-agent coordination that newer runtimes offer, you already get from Claude Code
> sub-agents (`doctrine/50-subagents.md`). Don't add a moving part you don't need.

## Tools — install, don't wait

If a capability is missing, get it; don't abandon a good hypothesis because a tool isn't
installed.

- System packages: `sudo -A apt-get install -y <pkg>` (a non-interactive askpass is wired,
  so sudo won't hang; **never** type a password into a command line — it would be logged).
- User space, no root: `pipx install …`, `pip install --user …`, `go install …`,
  `git clone` + build, or a static binary dropped in the run's `bin/`.
- Downloaded binaries/repos are **untrusted**: keep each in its own directory under the run
  dir, read before you run, pass paths as arguments, and don't launch interpreters from
  inside an untrusted directory (a planted `json.py` would hijack `import json`).

## Build what doesn't exist

Insane boxes routinely need a bespoke script: a custom client for an odd protocol, a
padding-oracle or hash-length-extension harness, a race-condition driver, a tailored
fuzzer, a deserialization gadget chain, a decryptor. **Write it.** Any tool/script you
author goes in the run's `tools/` with a one-line purpose comment on top; delegate the
heavier exploit code to the `exploit-dev` sub-agent and keep the raw payloads in `exploit/`.
A tool you built and understand beats a downloaded one you don't.

## Wordlists & local resources

`$SECLISTS` points at a full SecLists install; prefer it over guessing paths. Other
curated resources (PayloadsAllTheThings, GTFOBins, compiled binaries, etc.) may be present
under the configured `files_etc` dir — check before fetching from the internet, but don't
hesitate to fetch when local doesn't have it.

## Visual content

If the only data is visual (a screenshot, a rendered page, a PDF, an RDP/GUI kiosk),
resolve it in priority order: **(1)** get the real underlying data (fetch the file,
source, or API) → **(2)** OCR to extract greppable text → **(3)** capture an image and
`Read` it (Claude Code reads PNG/JPG/PDF natively). A single image you already have: just
`Read` it.
