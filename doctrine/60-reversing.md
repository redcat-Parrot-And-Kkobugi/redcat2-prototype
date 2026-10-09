# 60 — Reversing & Dynamic Analysis

When a box hands you a binary — a custom service, a SUID program, firmware, a compiled
client, a crackme — reversing is often the whole box. Two tools are wired in: **IDA Pro
9.3** (static, with the ida-pro-mcp server) and **gdb** with its plugins (dynamic). The
rules below exist to keep this fast and cheap: static analysis produces a lot of text, and
round-tripping every function through the MCP burns tokens and time.

## Static: IDA — export first, then grep

**Do not interrogate IDA function-by-function over MCP.** That is the slow, expensive path.
Instead:

1. **Export the decompilation to files, once.** Dump Hex-Rays pseudocode for every function
   (and the strings/imports/exports) to plain `.c`/`.txt` under `reversing/<binary>/`. Use
   the IDA MCP (or a headless `idat` IDAPython script) to bulk-decompile:
   - all functions → `reversing/<bin>/pseudo.c` (one function after another)
   - strings → `reversing/<bin>/strings.txt`, imports → `imports.txt`, exports/symbols too
2. **Search the exported files with `grep`/`rg`, not the MCP.** Hunt logic and strings
   locally: `rg -n 'system|exec|strcpy|memcpy|/bin/sh|password|secret|FLAG' reversing/<bin>/`.
   This is where you find the interesting functions, dangerous calls, format strings, hard
   coded secrets, and command handlers — at zero MCP cost.
3. **Only then go back to IDA MCP, surgically.** For the handful of functions that matter:
   pull targeted xrefs, re-decompile a single function after you've renamed/retyped a
   variable, check a struct layout, follow one call graph. Narrow queries, not sweeps.

Rationale: reading a 2000-line exported `pseudo.c` with `grep` costs a grep; asking the
model to pull every function over MCP costs thousands of tokens and floods context. Export
once, search locally, query IDA only for the targeted follow-ups. Keep the exports on disk
as evidence (`reversing/`), same as any scan output.

Delegate the whole static pass to the **`reverser`** sub-agent: hand it the binary and what
you're looking for; it does the export + local search and returns the few functions and
facts that matter, keeping the raw decompilation out of your context.

## Dynamic: gdb in tmux

Debugging is interactive and stateful, so it runs in **tmux**, never as one-shot commands.
Your gdb has its plugin set (pwndbg/gef-style) auto-loading from `~/.gdbinit`.

- Open a dedicated debug session: `<tmux_base>_dbg` (e.g. `tmux new-session -d -s rc2_<slug>_dbg`).
  Keep it alive across loop iterations — the debuggee, breakpoints, and layout persist there.
- Drive it with `tmux send-keys -t <sess> '<gdb cmd>' Enter` and read state back with
  `tmux capture-pane -p -t <sess>`. Look at the pane before sending the next command, exactly
  as you would watch a real terminal.
- Typical flow: load the target (`gdb ./bin` or attach to a pid/remote), set breakpoints at
  the functions your static pass flagged, run with controlled input, inspect registers/stack/
  heap at each stop, and confirm the primitive you're after (overflow offset, leaked pointer,
  a branch you can influence). The plugin's `telescope`/`heap`/`vmmap` views are your eyes.
- For a remote/networked target binary, debug a local copy to understand it, then drive the
  real service over the network with the exploit you built (see `exploit-dev`).

## From analysis to exploit

Reversing is in service of a hypothesis, under the same evidence budget as everything else.
The output of a reversing pass is a concrete primitive and a plan — "function `handle_cmd`
does `system()` on attacker input after a check I can bypass by X" — which you hand to
`exploit-dev` to build the actual payload. Don't reverse further than the box needs: once
you have a working primitive, pivot to exploitation.
