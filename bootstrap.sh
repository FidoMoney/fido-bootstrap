#!/bin/bash
#
# Fido Bootstrap (macOS) — stage 1 of 2
# -------------------------------------
# The Fido installer lives in a private repo, so a brand-new Mac can't just
# curl it: there's no GitHub credential on the machine yet. This public stub
# gets you a GitHub CLI, signs you in, then fetches and runs the real
# installer from FidoMoney/fido-installer.
#
# Quickstart (new employees):
#   bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-bootstrap/main/bootstrap.sh)
#
# Run it with process substitution as above — NEVER `curl ... | bash`. Piping
# makes this script the shell's stdin, so the GitHub login prompt and every
# question the installer asks would read leftover script text instead of you.
#
# Re-running is safe: same command, any time.
#
# Every argument is passed straight through to the installer, e.g.
#   bash <(curl -fsSL .../bootstrap.sh) --profile expert --dry-run
#
# Environment:
#   FIDO_INSTALLER_REF=<ref>   git ref of fido-installer to fetch (default: main)
#

set -euo pipefail

INSTALLER_REPO="FidoMoney/fido-installer"
INSTALLER_FILE="install.sh"
INSTALLER_REF="${FIDO_INSTALLER_REF:-main}"
GH_LATEST_API="https://api.github.com/repos/cli/cli/releases/latest"

# ── Colors & Helpers ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2;37m'
PINK='\033[38;2;214;8;107m'   # Fido brand pink (#d6086b)
NC='\033[0m'

# Diagnostics go to stderr so helpers that return a value on stdout
# (ensure_gh → path to the gh binary) can print progress freely.
info()    { echo -e "${BLUE}ℹ${NC}  $1" >&2; }
success() { echo -e "${GREEN}✔${NC}  $1" >&2; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1" >&2; }
fail()    { echo -e "${RED}✖${NC}  $1" >&2; }

# One scratch dir for the throwaway gh download and the fetched installer,
# removed however we exit.
BOOT_TMP="$(mktemp -d)"
cleanup() { [ -n "${BOOT_TMP:-}" ] && rm -rf "$BOOT_TMP"; return 0; }
trap cleanup EXIT

print_banner() {
    echo ""
    echo -e "${BOLD}${PINK}   Fido${NC} ${BOLD}Bootstrap${NC}"
    echo -e "${DIM}   by platform team${NC}"
    echo ""
    echo -e "  This will get a ${BOLD}GitHub CLI${NC}, sign you in to GitHub, then"
    echo -e "  download and run the Fido installer from ${BOLD}${INSTALLER_REPO}${NC}."
    echo ""
}

# Print the path to a usable gh. Prefers one already on PATH; otherwise
# downloads the official release build into the scratch dir — nothing is
# installed system-wide, and the installer puts a permanent gh in place
# later via Homebrew.
ensure_gh() {
    if command -v gh &> /dev/null; then
        success "GitHub CLI is already installed"
        command -v gh
        return 0
    fi

    local arch tag version url bin
    arch="$(uname -m)"
    case "$arch" in
        # The release assets are named amd64/arm64 — `uname -m` says x86_64
        # on Intel, which is the same thing by another name.
        arm64 | aarch64) arch="arm64" ;;
        x86_64 | amd64)  arch="amd64" ;;
        *) fail "Unsupported CPU architecture '${arch}' — install gh yourself: brew install gh"; return 1 ;;
    esac

    info "Fetching a temporary GitHub CLI (nothing is installed system-wide)..."
    if ! tag="$(curl -fsSL "$GH_LATEST_API" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null)"; then
        fail "Couldn't ask github.com for the latest GitHub CLI release."
        fail "Install it yourself and re-run this command:  ${BOLD}brew install gh${NC}"
        return 1
    fi
    version="${tag#v}"
    [ -n "$version" ] || { fail "Couldn't read the GitHub CLI version number"; return 1; }

    url="https://github.com/cli/cli/releases/download/${tag}/gh_${version}_macOS_${arch}.zip"
    if ! curl -fsSL "$url" -o "${BOOT_TMP}/gh.zip"; then
        fail "Couldn't download ${url}"
        fail "Install gh yourself and re-run this command:  ${BOLD}brew install gh${NC}"
        return 1
    fi
    if ! unzip -q "${BOOT_TMP}/gh.zip" -d "${BOOT_TMP}/gh"; then
        fail "Couldn't unpack the GitHub CLI archive"
        return 1
    fi

    # Archive layout is gh_<version>_macOS_<arch>/bin/gh.
    bin="${BOOT_TMP}/gh/gh_${version}_macOS_${arch}/bin/gh"
    if [ ! -x "$bin" ]; then
        bin="$(find "${BOOT_TMP}/gh" -type f -name gh -perm -u+x 2>/dev/null | head -1)"
    fi
    if [ -z "$bin" ] || ! "$bin" --version >/dev/null 2>&1; then
        fail "The downloaded GitHub CLI doesn't run — install it yourself: ${BOLD}brew install gh${NC}"
        return 1
    fi
    success "GitHub CLI ${version} ready (temporary)"
    echo "$bin"
}

ensure_gh_auth() {
    local gh="$1"
    if "$gh" auth status -h github.com &> /dev/null; then
        success "Already signed in to GitHub"
        return 0
    fi
    # `gh auth login -w` waits on a browser and a one-time code, so with no
    # terminal attached it would hang forever instead of failing. Say what's
    # wrong and stop. (`[ -r /dev/tty ]` isn't enough on macOS — the device
    # file is always readable but opening it fails with no controlling
    # terminal, so probe with a real open.)
    if ! (exec </dev/tty) 2>/dev/null; then
        fail "Not signed in to GitHub, and there's no terminal here to sign in with."
        fail "Run this from a normal terminal, or set ${BOLD}GH_TOKEN${NC} to a token with repo read access."
        return 1
    fi
    info "Signing you in to GitHub — a browser window will open."
    info "Pick ${BOLD}HTTPS${NC} if you're asked how to authenticate."
    echo ""
    if ! "$gh" auth login -h github.com -p https -w; then
        fail "GitHub sign-in didn't complete — re-run this command to try again."
        return 1
    fi
    success "Signed in to GitHub"
}

# Download install.sh from the private repo into $1. Distinguishes "you're
# not in the org yet" (the common new-hire case) from a real network fault.
fetch_installer() {
    local gh="$1" dest="$2" err rc=0

    info "Fetching ${INSTALLER_FILE} from ${INSTALLER_REPO} (ref: ${INSTALLER_REF})..."
    # `2>&1 >"$dest"` sends stderr to the command substitution and stdout to
    # the file — order matters, and it lets us keep gh's error text for the
    # 404-vs-network diagnosis below.
    err="$("$gh" api -H "Accept: application/vnd.github.raw" \
        "repos/${INSTALLER_REPO}/contents/${INSTALLER_FILE}?ref=${INSTALLER_REF}" 2>&1 >"$dest")" || rc=$?

    if [ "$rc" -ne 0 ]; then
        if printf '%s' "$err" | grep -qE 'HTTP 40[34]|Not Found|Must have admin rights'; then
            echo "" >&2
            fail "Your GitHub account isn't in the FidoMoney org yet — ask in #eng-platform for an invite, then re-run this command."
            if [ "$INSTALLER_REF" != "main" ]; then
                fail "  (FIDO_INSTALLER_REF is set to '${INSTALLER_REF}' — a ref that doesn't exist in ${INSTALLER_REPO} shows this same error.)"
            fi
        elif printf '%s' "$err" | grep -q 'HTTP 401'; then
            fail "GitHub rejected your credentials — run ${BOLD}gh auth login${NC} and re-run this command."
        else
            fail "Couldn't download ${INSTALLER_FILE} from ${INSTALLER_REPO}."
            [ -n "$err" ] && fail "  ${err}"
            fail "Check your network (or VPN/proxy) and re-run this command."
        fi
        return 1
    fi

    if [ ! -s "$dest" ]; then
        fail "Downloaded an empty ${INSTALLER_FILE} — re-run this command."
        return 1
    fi
    success "Downloaded the Fido installer"
}

# ── Flow ────────────────────────────────────────────────────────────
print_banner

if ! GH_BIN="$(ensure_gh)"; then
    exit 1
fi

if ! ensure_gh_auth "$GH_BIN"; then
    exit 1
fi

INSTALLER_PATH="${BOOT_TMP}/${INSTALLER_FILE}"
if ! fetch_installer "$GH_BIN" "$INSTALLER_PATH"; then
    exit 1
fi

# Hand over. `|| rc=$?` keeps `set -e` from skipping the exit below, so the
# installer's status is what the user (and any CI wrapping this) sees, and
# the EXIT trap still cleans up the scratch dir.
echo ""
rc=0
bash "$INSTALLER_PATH" "$@" || rc=$?
exit "$rc"
