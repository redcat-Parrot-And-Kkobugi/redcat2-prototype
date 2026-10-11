# Surface signals — observation → environment → direction (NOT a playbook)

Consulted (per `doctrine/10-hunt-loop.md` → ORIENT) when the port surface is thin/filtered and the
box is not obviously dead. It turns a **generalizable** fingerprint into the next *research /
hypothesis direction* — never a fixed sequence of steps. The epistemic loop
(ORIENT → RESEARCH → EXPERIMENT → VERIFY) still does the actual solving.

**Rules for this file (keep it a pointer, not a playbook):**
- Each row is ONLY: a signal you can observe · the environment it *likely* indicates · the
  question/direction it opens. **No ordered steps, no commands-to-run-in-sequence, no per-box
  solutions.**
- Add a row only when the signal is **generalizable** — it would mean the same on a different
  target. A one-off detail belongs in that run's `worldmodel.md`, not here.
- A signal is a pointer to a *hypothesis*, not a verdict — confirm it with evidence before trusting it.
- Extend this as you learn; if a row starts turning into steps, it's drifting into a playbook — cut it back.

| signal (observed) | likely environment | direction it opens (research / hypothesis) |
|---|---|---|
| most/all TCP filtered, but a hostname / web vhost still answers | app- or cloud-fronted, not port-exposed | the real entry is the app/API, not raw ports — enumerate *that* as the surface |
| `AKIA…` / `ASIA…` token, or `aws_access_key_id=` in a file/response | AWS credentials in hand | whose identity is it and what may it do? research that cloud's identity + permission model |
| `169.254.169.254` reachable (often via SSRF) | cloud instance metadata service | what does this cloud's metadata expose to an unauthenticated local caller? |
| host/URL under `*.amazonaws.com` / `*.blob.core.windows.net` / `*.storage.googleapis.com` | cloud-fronted object storage | is the bucket/container/object world-readable or mis-scoped? |
| a `Server:` / framework banner or version you don't know cold | some app/framework | research that exact product + version for known issues before poking (`doctrine/20`) |

_This list is a seed showing the format, not an inventory. Grow it from your own confirmed, generalizable findings._
