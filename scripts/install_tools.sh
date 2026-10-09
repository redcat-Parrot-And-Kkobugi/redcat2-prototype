#!/usr/bin/env bash
# redcat2 — install the Kali toolset the doctrine expects (standalone). Authorized labs only.
#
# Covers recon → enum → access → user → privesc → pivot → root, plus Cloud + AD:
#   Recon · Enumeration · Initial Access · User · PrivEsc · Pivot · Root/Loot,
#   plus the Cloud (AWS/Azure/GCP) and Active-Directory tracks.
#
# Target OS: Kali Linux Rolling (uses apt + pipx + go + git). Authorized labs only.
#
# Usage:
#   ./scripts/install_tools.sh            # MAX: full toolset (default) — apt + pipx + go + git + SecLists + files_etc extras
#   ./scripts/install_tools.sh core       # CORE: apt packages only (lightweight base)
#   ./scripts/install_tools.sh max        # MAX, explicit
#   ./scripts/install_tools.sh --check    # only print what is present / missing
#   SKIP_CLOUD=1 ./scripts/install_tools.sh   # skip aws/az/gcloud CLIs
#   SKIP_PYENV=1 ./scripts/install_tools.sh   # skip the redcat venv bootstrap
#
# Safe to re-run: every step is idempotent and a single failure never aborts the rest.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT_DIR="/opt"                       # git-cloned tools live here (Kali convention)
GOBIN_DIR=""                         # resolved at runtime by detect_bindir() — never hardcoded
FILES_ETC="${FILES_ETC:-$HOME/files_etc}"   # extra tools/resources git-cloned here (max mode)
FAILED=()                            # collected non-fatal failures, printed at the end

c_ok()   { printf '\033[32m  ok  \033[0m %s\n' "$*"; }
c_skip() { printf '\033[33m skip \033[0m %s\n' "$*"; }
c_info() { printf '\033[36m ---- \033[0m %s\n' "$*"; }
c_fail() { printf '\033[31m FAIL \033[0m %s\n' "$*"; FAILED+=("$*"); }
have()   { command -v "$1" >/dev/null 2>&1; }

SUDO=""
need_sudo() {
  [ "$(id -u)" -eq 0 ] && return 0
  if have sudo; then SUDO="sudo"; return 0; fi
  c_fail "not root and no sudo — apt/go/opt steps will be skipped"; return 1
}

# ---- the full tool inventory, grouped by install method -------------------------

# apt: everything Kali packages. (verified against the Kali Rolling repo)
APT_PKGS=(
  # recon / scanning
  nmap rustscan masscan amass subfinder dnsrecon dnsenum bind9-dnsutils
  onesixtyone snmp
  # web enumeration
  gobuster ffuf feroxbuster wfuzz nikto whatweb wpscan nuclei sqlmap
  # smb / ldap / nfs / ad enumeration
  smbclient smbmap enum4linux-ng ldap-utils responder mitm6
  netexec crackmapexec nfs-common
  # impacket (secretsdump.py, GetUserSPNs.py, getTGT.py, getST.py, rbcd.py, ...)
  impacket-scripts python3-impacket
  # ad attack / post-exploitation
  evil-winrm bloodhound bloodhound.py neo4j certipy-ad bloodyad
  # exploitation / shells / pivoting
  metasploit-framework exploitdb hydra chisel ligolo-ng proxychains4 socat
  netcat-traditional sshpass
  # vpn (HTB lab connectivity)
  openvpn
  # privesc helpers
  peass pspy linux-exploit-suggester
  # hash cracking
  hashcat john hashid
  # cloud
  s3scanner
  # loot / forensics / misc
  libimage-exiftool-perl steghide binwalk foremost jq git curl wget tmux openssl
  # base utils required by other tools (bsdextrautils provides `rev`, which searchsploit needs)
  bsdextrautils
  # toolchains needed by the pipx / go / git steps below (+ requests for exploit scripts)
  pipx python3-venv python3-requests
)

# pipx: Python tools Kali does not package
PIPX_PKGS=( scoutsuite prowler )

# go install: Go tools not in apt (module path -> resulting binary name)
declare -A GO_PKGS=(
  ["github.com/BishopFox/cloudfox@latest"]="cloudfox"
  ["github.com/ropnop/kerbrute@latest"]="kerbrute"   # fallback only; apt kerbrute preferred
)

# git clone into /opt: tools shipped only as repos
declare -A GIT_REPOS=(
  ["https://github.com/internetwache/GitTools"]="GitTools"
  ["https://github.com/initstring/cloud_enum"]="cloud_enum"
)

# wordlists: SecLists via git clone into the user's home (no apt/sudo), not /usr/share
SECLISTS_DIR="${SECLISTS_DIR:-$HOME/files_etc/SecLists}"
SECLISTS_DIR="${SECLISTS_DIR/#\~/$HOME}"   # expand a literal leading ~

# MAX mode: extra HTB-useful resources not in apt — git-cloned into $FILES_ETC.
# Forward-staged (so they're ready before a solve needs them) + curated from the team's
# "useful-tools" references. dest-name -> repo URL.
declare -A MAX_GIT_REPOS=(
  ["PayloadsAllTheThings"]="https://github.com/swisskyrepo/PayloadsAllTheThings"   # payloads/technique bible
  ["GTFOBins"]="https://github.com/GTFOBins/GTFOBins.github.io"                    # sudo/SUID privesc data (offline grep)
  ["Ghostpack-CompiledBinaries"]="https://github.com/r3motecontrol/Ghostpack-CompiledBinaries"  # Rubeus/Seatbelt/Certify .exe
  ["pwncat"]="https://github.com/calebstewart/pwncat"                              # post-exploit shell (team-referenced)
  # --- user-specified (clone into files_etc) ---
  ["hacktricks"]="https://github.com/HackTricks-wiki/hacktricks"                   # the HackTricks wiki (huge RAG ref)
  ["RedTeam-Tools"]="https://github.com/A-poc/RedTeam-Tools"                       # curated red-team tool index
  ["smbmap-src"]="https://github.com/shawndevans/smbmap"                           # smbmap source (binary also via apt)
  ["evil-winrm-src"]="https://github.com/hackplayers/evil-winrm"                   # evil-winrm source (binary also via apt)
  ["dnSpy"]="https://github.com/dnspy/dnspy"                                       # .NET debugger/decompiler (Windows)
  ["ILSpy"]="https://github.com/icsharpcode/ilspy"                                 # .NET decompiler
  ["PowerSploit"]="https://github.com/PowerShellMafia/PowerSploit"                 # PS offensive modules (upload to target)
  ["Rubeus"]="https://github.com/ghostpack/rubeus"                                 # Rubeus source (compiled in Ghostpack-*)
)

# large crack dictionary (CrackStation) — fetched into $FILES_ETC/wordlists in max mode.
# human-only by default (~247 MiB gz); set CRACKSTATION_FULL=1 for the 4.2 GiB / 15 GiB list.
CRACKSTATION_FULL="${CRACKSTATION_FULL:-0}"

# ---- steps ----------------------------------------------------------------------

install_apt() {
  need_sudo || return
  c_info "apt: updating package lists"
  $SUDO apt-get update -qq || c_fail "apt-get update"
  # install one-by-one so a single unavailable package can't block the rest
  local missing=()
  for p in "${APT_PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 && continue
    missing+=("$p")
  done
  if [ ${#missing[@]} -eq 0 ]; then c_ok "all apt packages already present"; return; fi
  c_info "apt: installing ${#missing[@]} package(s): ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -q "${missing[@]}" \
    && c_ok "apt batch installed" \
    || { c_info "batch failed — retrying individually"; for p in "${missing[@]}"; do
           DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -q "$p" \
             && c_ok "apt $p" || c_fail "apt $p"; done; }
}

install_pipx() {
  have pipx || { c_fail "pipx missing — skipping ScoutSuite/Prowler"; return; }
  pipx ensurepath >/dev/null 2>&1 || true
  for p in "${PIPX_PKGS[@]}"; do
    have "$p" && { c_skip "pipx $p (present)"; continue; }
    pipx install "$p" >/dev/null 2>&1 && c_ok "pipx $p" || c_fail "pipx $p"
  done
}

# Pick the bin dir already in use on $PATH (writable) to drop go binaries into — not hardcoded.
# Priority: explicit $GOBIN → a writable PATH dir under $HOME → any writable PATH dir → ~/.local/bin.
detect_bindir() {
  if [ -n "${GOBIN:-}" ]; then printf '%s\n' "$GOBIN"; return; fi
  local d; local IFS=:
  for d in $PATH; do case "$d" in "$HOME"/*) [ -d "$d" ] && [ -w "$d" ] && { printf '%s\n' "$d"; return; };; esac; done
  for d in $PATH; do [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ] && { printf '%s\n' "$d"; return; }; done
  mkdir -p "$HOME/.local/bin"; printf '%s\n' "$HOME/.local/bin"
}

install_go() {
  have go || { c_fail "go missing — skipping cloudfox/kerbrute go-install"; return; }
  GOBIN_DIR="$(detect_bindir)"; export GOBIN="$GOBIN_DIR"; mkdir -p "$GOBIN"
  c_info "go binaries → $GOBIN_DIR (detected on PATH)"
  local did_install=0
  for mod in "${!GO_PKGS[@]}"; do
    local bin="${GO_PKGS[$mod]}"
    if [ -x "$GOBIN_DIR/$bin" ] || have "$bin"; then
      c_skip "go $bin (present)"; continue
    fi
    c_info "go install $mod → $GOBIN_DIR"
    go install "$mod" >/dev/null 2>&1 && { c_ok "go $bin"; did_install=1; } || c_fail "go $bin"
  done
  case ":$PATH:" in *":$GOBIN_DIR:"*) ;; *)
    c_info "note: $GOBIN_DIR is not on PATH — add it so cloudfox/kerbrute resolve";;
  esac
  # drop the Go module cache so it doesn't leave a multi-GB ~/go behind
  # (binaries live in ~/.local/bin, not ~/go — the manager Go stays at /usr/local/go)
  if [ "$did_install" -eq 1 ]; then
    # drop BOTH the module cache (~/go/pkg/mod) and the build cache (~/.cache/go-build);
    # building cloudfox alone leaves a multi-GB build cache. Binaries in $GOBIN are unaffected.
    GOFLAGS= go clean -cache -modcache >/dev/null 2>&1 && c_ok "go build+module caches cleaned"
    [ -d "$HOME/go" ] && rmdir "$HOME/go/bin" "$HOME/go/pkg" "$HOME/go" 2>/dev/null || true
  fi
}

install_git_repos() {
  need_sudo || return
  for url in "${!GIT_REPOS[@]}"; do
    local name="${GIT_REPOS[$url]}" dest
    dest="$OPT_DIR/$name"
    if [ -d "$dest/.git" ]; then
      $SUDO git -C "$dest" pull -q && c_ok "git $name (updated)" || c_fail "git pull $name"
    else
      $SUDO git clone -q "$url" "$dest" && c_ok "git $name -> $dest" || c_fail "git clone $name"
    fi
  done
  # convenience launcher for cloud_enum
  if [ -f "$OPT_DIR/cloud_enum/cloud_enum.py" ] && ! have cloud_enum; then
    $SUDO ln -sf "$OPT_DIR/cloud_enum/cloud_enum.py" /usr/local/bin/cloud_enum \
      && $SUDO chmod +x "$OPT_DIR/cloud_enum/cloud_enum.py" && c_ok "linked cloud_enum"
  fi
}

install_cloud_clis() {
  if [ "${SKIP_CLOUD:-0}" = "1" ]; then c_skip "cloud CLIs (SKIP_CLOUD=1)"; return; fi
  need_sudo || return
  # awscli + azure-cli are in the Kali repo; install via apt here so they are optional.
  for p in awscli azure-cli; do
    dpkg -s "$p" >/dev/null 2>&1 && { c_skip "$p (present)"; continue; }
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -q "$p" \
      && c_ok "apt $p" || c_fail "apt $p"
  done
  # gcloud is not in the Kali repo — install Google's SDK via pipx-style tarball note.
  if have gcloud; then c_skip "gcloud (present)"; else
    c_info "gcloud not packaged for Kali — install manually if you do GCP work:"
    c_info "  https://cloud.google.com/sdk/docs/install  (or: pipx install gcloud is NOT official)"
  fi
}

bootstrap_redcat() {
  if [ "${SKIP_PYENV:-0}" = "1" ]; then c_skip "python venv (SKIP_PYENV=1)"; return; fi
  [ -f "$ROOT/pyproject.toml" ] || { c_skip "python venv (redcat2 has no Python package — tools only)"; return; }
  c_info "redcat: Python venv + editable install"
  local py="$ROOT/.venv/bin/python"
  [ -x "$py" ] || python3 -m venv --without-pip "$ROOT/.venv" || { c_fail "venv create"; return; }
  if ! "$py" -m pip --version >/dev/null 2>&1; then
    "$py" -m ensurepip >/dev/null 2>&1 || {
      c_info "bootstrapping pip via get-pip.py"
      local gp; gp="$(mktemp)"
      curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$gp" && "$py" "$gp" >/dev/null 2>&1
      rm -f "$gp"
    }
  fi
  "$py" -m pip install -q -e "$ROOT" && c_ok "redcat installed in .venv" || c_fail "redcat pip install"
}

ensure_seclists() {
  local rockyou="$SECLISTS_DIR/Passwords/Leaked-Databases/rockyou.txt"
  if [ -d "$SECLISTS_DIR/Discovery" ]; then
    c_skip "SecLists present ($SECLISTS_DIR)"
  else
    mkdir -p "$(dirname "$SECLISTS_DIR")"
    # SecLists is large; a plain git clone often dies with 'early EOF/invalid index-pack'.
    # Try a tuned shallow clone, then fall back to the tarball (single stream, reliable).
    c_info "fetching SecLists (shallow clone) → $SECLISTS_DIR"
    if git -c http.postBuffer=524288000 clone --depth 1 \
         https://github.com/danielmiessler/SecLists.git "$SECLISTS_DIR" >/dev/null 2>&1; then
      c_ok "SecLists cloned"
    else
      c_info "clone failed — downloading tarball instead"
      rm -rf "$SECLISTS_DIR"
      local tb; tb="$(dirname "$SECLISTS_DIR")/seclists.tar.gz"
      if curl -fL --retry 3 -o "$tb" \
           https://codeload.github.com/danielmiessler/SecLists/tar.gz/refs/heads/master >/dev/null 2>&1 \
         && tar -xzf "$tb" -C "$(dirname "$SECLISTS_DIR")" \
         && mv "$(dirname "$SECLISTS_DIR")/SecLists-master" "$SECLISTS_DIR"; then
        rm -f "$tb"; c_ok "SecLists (tarball) → $SECLISTS_DIR"
      else
        rm -f "$tb"; c_fail "SecLists fetch (clone + tarball both failed)"; return
      fi
    fi
  fi
  # extract rockyou once (SecLists ships it gzip/tar compressed)
  if [ ! -s "$rockyou" ]; then
    local d="$SECLISTS_DIR/Passwords/Leaked-Databases"
    if   [ -f "$d/rockyou.txt.tar.gz" ]; then ( cd "$d" && tar -xzf rockyou.txt.tar.gz ) && c_ok "rockyou extracted"
    elif [ -f "$d/rockyou.txt.gz" ];     then gunzip -k "$d/rockyou.txt.gz" && c_ok "rockyou extracted"
    else c_info "rockyou archive not found under $d (skip)"; fi
  fi
}

# MAX mode: clone the curated extra repos into $FILES_ETC (idempotent, shallow).
ensure_files_etc_repos() {
  mkdir -p "$FILES_ETC"
  local name url dest
  for name in "${!MAX_GIT_REPOS[@]}"; do
    url="${MAX_GIT_REPOS[$name]}"; dest="$FILES_ETC/$name"
    if [ -d "$dest/.git" ] || [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
      c_skip "files_etc/$name (present)"; continue
    fi
    if git -c http.postBuffer=524288000 clone --depth 1 "$url" "$dest" >/dev/null 2>&1; then
      c_ok "files_etc/$name"
    else
      rm -rf "$dest"
      local tb="$FILES_ETC/.$name.tar.gz"
      if curl -fsSL --retry 3 -o "$tb" "${url%/}/archive/refs/heads/master.tar.gz" 2>/dev/null \
         && tar -xzf "$tb" -C "$FILES_ETC" 2>/dev/null \
         && mv "$FILES_ETC/$(basename "$url")-master" "$dest" 2>/dev/null; then
        rm -f "$tb"; c_ok "files_etc/$name (tarball)"
      else
        rm -f "$tb"; c_fail "files_etc/$name (clone + tarball failed — try branch 'main')"
      fi
    fi
  done
  # pwncat is also a maintained pip package; make the CLI available if pipx is present
  if have pipx && ! have pwncat-cs; then
    pipx install pwncat-cs >/dev/null 2>&1 && c_ok "pipx pwncat-cs" || c_info "pwncat-cs via pipx skipped"
  fi
}

# MAX mode: CrackStation crack dictionary → $FILES_ETC/wordlists (human-only by default).
ensure_crackstation() {
  local wd="$FILES_ETC/wordlists"; mkdir -p "$wd"
  local name="crackstation-human-only" md5="fbc3ca43230086857aac9b71b588a574"
  if [ "$CRACKSTATION_FULL" = "1" ]; then name="crackstation"; md5="4748a72706ff934a17662446862ca4f8"; fi
  local gz="$wd/$name.txt.gz" txt="$wd/$name.txt"
  if [ -s "$txt" ]; then c_skip "crackstation ($name present)"; return; fi
  c_info "downloading CrackStation $name (this is large) → $gz"
  if curl -fL --retry 3 -C - -o "$gz" "https://crackstation.net/files/$name.txt.gz" 2>/dev/null; then
    local got; got="$(md5sum "$gz" | cut -d' ' -f1)"
    [ "$got" = "$md5" ] && c_ok "crackstation md5 ok" || c_fail "crackstation md5 mismatch ($got)"
    gunzip -k "$gz" 2>/dev/null && c_ok "crackstation → $txt" || c_fail "crackstation gunzip"
  else
    c_fail "crackstation download"
  fi
}

# ---- verification ----------------------------------------------------------------

# binary names to probe (what you actually type), mapped from the inventory above
VERIFY=(
  nmap rustscan masscan amass subfinder dnsrecon dnsenum dig onesixtyone snmpwalk
  gobuster ffuf feroxbuster wfuzz nikto whatweb wpscan nuclei sqlmap
  smbclient smbmap enum4linux-ng ldapsearch responder mitm6 netexec crackmapexec
  impacket-secretsdump impacket-GetUserSPNs impacket-getTGT evil-winrm bloodhound-python neo4j
  certipy-ad bloodyad kerbrute cloudfox
  msfconsole searchsploit hydra chisel proxychains4 socat nc openvpn sshpass
  rev showmount linpeas.sh pspy hashcat john hashid
  aws az s3scanner scout prowler
  exiftool steghide binwalk foremost jq git curl wget tmux openssl
)

verify() {
  c_info "verification (binary on PATH?)"
  local present=0 absent=0
  for b in "${VERIFY[@]}"; do
    if have "$b" || compgen -G "/usr/share/peass/**/$b" >/dev/null 2>&1 \
         || [ -e "/usr/share/peass/linpeas/$b" ]; then
      printf '  \033[32m✓\033[0m %s\n' "$b"; present=$((present+1))
    else
      printf '  \033[31m✗\033[0m %s\n' "$b"; absent=$((absent+1))
    fi
  done
  echo
  c_info "present: $present   missing: $absent"
  # wordlists readiness (SecLists git clone, not apt)
  if [ -d "$SECLISTS_DIR/Discovery" ]; then printf '  \033[32m✓\033[0m %s\n' "SecLists ($SECLISTS_DIR)"
  else printf '  \033[31m✗\033[0m %s\n' "SecLists missing — run installer (no --check) to fetch"; fi
  if [ -s "$SECLISTS_DIR/Passwords/Leaked-Databases/rockyou.txt" ]; then printf '  \033[32m✓\033[0m %s\n' "rockyou.txt (extracted)"
  else printf '  \033[31m✗\033[0m %s\n' "rockyou.txt not extracted"; fi
  # files_etc extra repos (max mode)
  for n in "${!MAX_GIT_REPOS[@]}"; do
    if [ -d "$FILES_ETC/$n" ] && [ -n "$(ls -A "$FILES_ETC/$n" 2>/dev/null)" ]; then printf '  \033[32m✓\033[0m %s\n' "files_etc/$n"
    else printf '  \033[31m✗\033[0m %s\n' "files_etc/$n (max mode)"; fi
  done
  if ls "$FILES_ETC"/wordlists/crackstation*.txt >/dev/null 2>&1; then printf '  \033[32m✓\033[0m %s\n' "crackstation wordlist"
  else printf '  \033[31m✗\033[0m %s\n' "crackstation wordlist (max mode)"; fi
  c_info "peass:     linpeas  -> /usr/share/peass/linpeas/linpeas.sh (also linux-exploit-suggester)"
}

main() {
  local mode="${1:-max}"
  case "$mode" in
    --check|check) verify; exit 0;;
    core) c_info "redcat tool installer — CORE (apt only) — authorized labs only";;
    max|"") mode="max"; c_info "redcat tool installer — MAX (full) — authorized labs only";;
    -h|--help) sed -n '10,16p' "$0"; exit 0;;
    *) echo "unknown mode '$mode' (use: core | max | --check)"; exit 2;;
  esac

  install_apt                       # both modes: apt packages
  if [ "$mode" = "max" ]; then
    install_pipx
    install_go
    install_git_repos
    install_cloud_clis
    ensure_seclists
    ensure_files_etc_repos          # curated extra repos → files_etc (incl. team-referenced)
    ensure_crackstation             # CrackStation crack dictionary → files_etc/wordlists
  else
    c_skip "CORE mode — skipping pipx / go / git / SecLists / files_etc (run 'max' for those)"
  fi
  bootstrap_redcat
  echo
  verify
  echo
  if [ ${#FAILED[@]} -gt 0 ]; then
    c_info "${#FAILED[@]} step(s) failed:"; printf '   - %s\n' "${FAILED[@]}"
    exit 1
  fi
  c_ok "done — $mode install complete"
}

main "$@"
