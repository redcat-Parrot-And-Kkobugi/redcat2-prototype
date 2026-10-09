#!/usr/bin/env python3
# conv_fmt.py — render Claude Code stream-json (one JSON event per line, from
# `claude -p --output-format stream-json --verbose`) into readable, colored lines.
#
# Reads JSONL on stdin, writes pretty lines on stdout, line-buffered (live feed).
# Used two ways:
#   - solve.sh: full view (assistant text + thinking + tool_use) alongside the raw
#     conv.jsonl it tees to logs/.
#   - watch.sh: pass --no-tools to show ONLY claude's reasoning (text/thinking)
#     (tool calls/outputs are already shown from logs/tools.jsonl there).
#
# Never raises on a bad line — unknown/garbage lines are passed through dim so the
# stream is never blocked.
import sys, json

C = {"cyan":"\033[36m","green":"\033[32m","yellow":"\033[33m","dim":"\033[2m",
     "red":"\033[31m","mag":"\033[35m","bold":"\033[1m","rst":"\033[0m"}
NO_TOOLS = "--no-tools" in sys.argv[1:]
NO_COLOR = "--no-color" in sys.argv[1:] or not sys.stdout.isatty()

def c(s, col):
    if NO_COLOR: return s
    return f"{C.get(col,'')}{s}{C['rst']}"

def emit(s):
    sys.stdout.write(s + "\n"); sys.stdout.flush()

def clip(s, n=2000):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n] + " …"

def tool_brief(blk):
    name = blk.get("name","tool")
    inp = blk.get("input",{}) or {}
    arg = inp.get("command") or inp.get("file_path") or inp.get("pattern") \
          or inp.get("url") or inp.get("description") or ""
    if not arg and inp:
        arg = clip(json.dumps(inp, ensure_ascii=False), 300)
    return name, clip(arg, 500)

for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw.strip():
        continue
    try:
        ev = json.loads(raw)
    except Exception:
        emit(c(clip(raw, 300), "dim")); continue
    t = ev.get("type")
    try:
        if t == "input":
            # synthetic records written by solve.sh: the exact inputs fed to claude
            sub = ev.get("subtype","")
            if sub == "system_prompt":
                emit(c(f"[input - system] → claude ({ev.get('chars','?')} chars)  full text in conv.jsonl / logs/system_prompt.txt", "mag"))
            elif sub == "launch":
                emit(c(f"[input - launch] model={ev.get('model','?')}  flags={ev.get('flags','') or '-'}", "mag"))
                if ev.get("prompt"):
                    emit(c("[input - prompt] " + clip(ev["prompt"], 6000), "cyan"))
            else:
                emit(c(f"[input - {sub}]", "mag"))
        elif t == "system":
            if ev.get("subtype") == "init":
                emit(c(f"[session] {ev.get('session_id','?')[:8]}  model={ev.get('model','?')}", "mag"))
        elif t == "assistant":
            for blk in ev.get("message",{}).get("content",[]) or []:
                bt = blk.get("type")
                if bt == "text" and blk.get("text","").strip():
                    emit(c("[agent] " + clip(blk["text"], 4000), "green"))
                elif bt == "thinking" and blk.get("thinking","").strip():
                    emit(c("[agent - thinking] " + clip(blk["thinking"], 2000), "dim"))
                elif bt == "tool_use" and not NO_TOOLS:
                    name, arg = tool_brief(blk)
                    emit(c(f"[tool - {name}] {arg}", "yellow"))
        elif t == "user":
            for blk in ev.get("message",{}).get("content",[]) or []:
                bt = blk.get("type") if isinstance(blk, dict) else None
                if bt == "tool_result":
                    if NO_TOOLS: continue
                    out = blk.get("content","")
                    if isinstance(out, list):
                        out = " ".join(x.get("text","") for x in out if isinstance(x, dict))
                    emit(c("[tool - result] " + clip(out, 1200), "dim"))
                elif bt == "text":
                    emit(c("[user] " + clip(blk.get("text",""), 2000), "cyan"))
            # content can also be a bare string
            mc = ev.get("message",{}).get("content")
            if isinstance(mc, str) and mc.strip():
                emit(c("[user] " + clip(mc, 2000), "cyan"))
        elif t == "result":
            if NO_TOOLS: continue
            dur = ev.get("duration_ms")
            cost = ev.get("total_cost_usd")
            sub = ev.get("subtype","")
            tail = f"  {dur}ms" if dur else ""
            tail += f"  ${cost:.4f}" if isinstance(cost,(int,float)) else ""
            emit(c(f"[result - {sub}]{tail}", "mag"))
        # rate_limit_event and others: ignore
    except Exception as e:
        emit(c(f"[conv_fmt] {e}: {clip(raw,200)}", "red"))
