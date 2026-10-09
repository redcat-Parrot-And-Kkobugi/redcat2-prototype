#!/usr/bin/env bash
# =============================================================================
#  scripts/auto_pr.sh — Stop-hook automation. When the working tree has changes,
#  it branches -> commits -> pushes -> opens a PR -> merges it, all on GitHub via
#  `gh`. Meant to run as a Claude Code Stop hook (end of each turn): the only turns
#  that produce a PR are the ones that actually changed a tracked file.
#
#  Reads the hook JSON on stdin (for session_id, used in attribution). It is a safe
#  no-op when there is nothing to commit, when gh/remote are unavailable, or when
#  already on an auto/* branch, and it NEVER fails the session (always exits 0).
#
#  Env knobs:
#    AUTO_PR_MODEL        attribution model name (default: Claude)
#    AUTO_PR_SESSION_URL  explicit Claude-Session URL (else built from session_id)
#    AUTO_PR_MERGE        merge method: squash|merge|rebase (default: squash)
#    AUTO_PR_DISABLE=1    skip entirely
# =============================================================================
set -uo pipefail

input="$(cat 2>/dev/null || true)"                       # hook JSON on stdin (empty if run by hand)
[ "${AUTO_PR_DISABLE:-0}" = "1" ] && exit 0

log(){ printf '[auto-pr] %s\n' "$*" >&2; }
jqr(){ printf '%s' "$input" | jq -r "$1" 2>/dev/null || true; }

# a Stop hook that was itself triggered by a block decision — never loop
[ "$(jqr '.stop_hook_active // false')" = "true" ] && exit 0

REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO" 2>/dev/null || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "not a git repo; skip"; exit 0; }
[ -z "$(git status --porcelain 2>/dev/null)" ] && exit 0            # nothing changed -> no PR

command -v gh >/dev/null 2>&1 || { log "gh not found; left changes uncommitted"; exit 0; }
gh auth status >/dev/null 2>&1 || { log "gh not authenticated; left changes uncommitted"; exit 0; }

BASE="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo main)"
case "$BASE" in auto/*) log "on $BASE (an auto branch); skip"; exit 0 ;; esac

ts="$(date +%Y%m%d-%H%M%S)"
branch="auto/${ts}"
files="$(git status --porcelain 2>/dev/null | sed 's/^...//; s/.* -> //' | head -4 | paste -sd', ' -)"
[ -n "$files" ] || files="working tree"
subject="chore: update ${files}"

model="${AUTO_PR_MODEL:-Claude}"
session_id="$(jqr '.session_id // empty')"
sess_url="${AUTO_PR_SESSION_URL:-}"
[ -z "$sess_url" ] && [ -n "$session_id" ] && sess_url="https://claude.ai/code/${session_id}"

git checkout -b "$branch" >/dev/null 2>&1 || { log "branch create failed"; exit 0; }
git add -A

cmsg=(-m "$subject" -m "Automated commit of the edits from this turn." \
      -m "Co-Authored-By: ${model} <noreply@anthropic.com>")
[ -n "$sess_url" ] && cmsg+=(-m "Claude-Session: ${sess_url}")
git commit -q "${cmsg[@]}" || { log "commit failed"; git checkout "$BASE" >/dev/null 2>&1; exit 0; }

if ! git push -u origin "$branch" >/dev/null 2>&1; then
  log "push failed; changes committed locally on $branch"; exit 0
fi

pr_body="Automated PR of the edits from this turn (${files})."$'\n\n'"🤖 Generated with [Claude Code](https://claude.com/claude-code)"
[ -n "$sess_url" ] && pr_body="${pr_body}"$'\n\n'"${sess_url}"

if ! gh pr create --base "$BASE" --head "$branch" --title "$subject" --body "$pr_body" >/dev/null 2>&1; then
  log "pr create failed; branch pushed as $branch"; git checkout "$BASE" >/dev/null 2>&1; exit 0
fi

if gh pr merge "$branch" --"${AUTO_PR_MERGE:-squash}" --delete-branch >/dev/null 2>&1; then
  log "merged $branch -> $BASE"
  git checkout "$BASE" >/dev/null 2>&1 || true
  git pull --ff-only origin "$BASE" >/dev/null 2>&1 || true
  git branch -D "$branch" >/dev/null 2>&1 || true
else
  log "merge failed (branch protection or pending checks?); PR left open for $branch"
  git checkout "$BASE" >/dev/null 2>&1 || true
fi
exit 0
