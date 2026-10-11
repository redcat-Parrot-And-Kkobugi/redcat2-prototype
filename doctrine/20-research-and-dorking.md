# 20 — Research & Google Dorking

On Insane boxes the decisive move is usually *knowing something the box's author assumed
you'd have to dig for*: an obscure CVE, a specific version's quirk, a default credential
buried in vendor docs, a chained bug from a conference talk. Research is a **first-class
offensive action**, equal to running a scan. You have the open internet — use it
deliberately, not as a last resort.

Most research should be **delegated to the `researcher` sub-agent** (it runs on a model
tuned for this and keeps the fetch volume out of your context). You hand it a sharp
question and your current facts; it returns a vetted brief. Reserve your own context for
strategy. See `doctrine/50-subagents.md`.

## Recall your own past runs first

Before (or alongside) hitting the live internet, check whether you've met this before:
`scripts/rag.sh <query>` greps every past run's `journal.md`, `worldmodel.md`, `hypotheses.md`,
`writeup.md`, and `failure_analysis.md`. A service, version, error string, or technique you (or
a prior run) already worked may have a recorded answer — what worked, and what turned out to be
a dead end. This is cheap memory across boxes; use it to avoid re-deriving and re-failing. Add
`-p` to also search the shared PayloadsAllTheThings / GTFOBins references.

## When to research (triggers)

- A service/product/framework you cannot reason about *cold*, or any version string at all
  (versions map to known bugs — always check).
- Any CVE id, advisory, or "known vulnerable" claim — read the primary source, not a headline.
- An unfamiliar error message, banner, header, cookie, or protocol behavior.
- Before running **any** public exploit — you read the code first (see "Vetting").
- When stuck: a different search, framed by a *new* fact, often unlocks a frozen hypothesis.

## Google dorking — operators

Dorking is precision search: constrain the result set with operators so you find the
exact artifact, not a sea of blog spam.

| Operator | Effect | Offensive use |
|---|---|---|
| `"exact phrase"` | literal match | error strings, banners, unique UI text |
| `site:` | one domain | `site:github.com`, `site:exploit-db.com`, `site:gist.github.com` |
| `inurl:` | term in URL | `inurl:CVE-2023`, admin paths, known endpoints |
| `intitle:` / `allintitle:` | term in page title | `intitle:"index of"`, advisory titles |
| `filetype:` / `ext:` | file type | `filetype:pdf` vendor guides, `ext:conf`, `ext:sql` |
| `-term` | exclude | cut noise: `-pinterest -youtube` |
| `OR` / `|` | alternatives | `rce OR "remote code"` |
| `*` | wildcard | `"CompanyApp * default password"` |
| `after:` / `before:` | date bound | `after:2023` for recent PoCs |

## Dork recipes for box research

Adapt `<product>` / `<version>` / `<error>` to your evidence:

```
"<product> <version>" (exploit OR CVE OR vulnerability)
<product> <version> site:github.com (poc OR exploit)
intitle:"<exact UI title>" default credentials
"<verbatim error string>"                       # often lands on the exact bug report
<product> site:exploit-db.com
CVE-2024-XXXXX poc site:github.com
"<product>" "config" (ext:conf OR ext:ini OR ext:yaml) site:github.com   # default/config leaks
<vendor> <appliance> default password filetype:pdf   # admin guides ship defaults
inurl:<unique-endpoint> <product>               # fingerprint confirmation
```

Beyond Google: **NVD/CVE** (authoritative details + affected ranges), **exploit-db** and
**GitHub** (PoCs), **vendor advisories & changelogs** (the fix commit often *is* the
exploit map), **HackerOne/writeups** for the *technique or vulnerability class* — never the
target box's own writeup/walkthrough (see `00-prime-directive.md` → No spoilers). The **Google Hacking
Database (GHDB)** is a catalogue of dorks worth mining for the target's tech.

## Vetting — read before you run

Public exploit code is untrusted input. Before running anything you found:

1. **Understand it.** Read the whole PoC. Know exactly what request/payload it sends and
   what side effect it causes. If you can't explain it line by line, you're not ready.
2. **Match it to the target.** Confirm the version/config/precondition actually matches
   your world model. A PoC for 4.2.0 may be harmless *or* destructive on 4.2.1.
3. **Watch for traps.** PoCs (especially random gists) can contain obfuscated payloads,
   hardcoded callbacks, or data-wipers. Have `verifier` review anything you don't fully
   trust. Treat downloaded files as untrusted: keep them in their own dir, pass them as
   arguments, don't execute from inside their directory.
4. **Prefer reproducing over trusting.** When feasible, rebuild the exploit from your
   understanding of the bug rather than running a stranger's binary — you'll control it,
   debug it, and adapt it to the box's specifics (which Insane boxes always require).

## From research to experiment

Research is not done when you've read; it's done when you have a **concrete, testable
experiment** and know what each outcome would prove. End every research pass by writing
that experiment into `hypotheses.md` (or the journal), then return to the hunt loop.
Never let research become its own rabbit hole — it serves a hypothesis, and the same
evidence-budget discipline applies.
