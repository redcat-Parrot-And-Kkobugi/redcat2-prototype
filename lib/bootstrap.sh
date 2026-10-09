#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh — redcat2 library loader. Sourced by ./hunt (and any script that
#  wants the full API). Sets $RC2_ROOT and pulls in the focused libs:
#    common.sh  colors, run-dir resolve, time helpers
#    env.sh     .env loading, SecLists, flag helpers
#    htb.sh     token refresh, machine resolve/spawn, VPN, flag watcher
#    run.sh     run-dir scaffold, prompt assembly, resilient run loop
#  Fully standalone: HTB API client, HAR extractor, and log renderer are bundled.
# =============================================================================
RC2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# $SECLISTS (~/files_etc/SecLists) is a shared external wordlist resource, not a sibling project.

. "$RC2_ROOT/lib/common.sh"
. "$RC2_ROOT/lib/env.sh"
. "$RC2_ROOT/lib/htb.sh"
. "$RC2_ROOT/lib/run.sh"
