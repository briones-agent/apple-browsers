#!/usr/bin/env bash
#
# commission-safari.sh — one-time, human-run setup that makes a macOS box able to
# run test-safari.sh over SSH afterwards. Run this ONCE from the VM's GUI Terminal
# (Screen Sharing / physical console) — NOT over SSH: trusting a cert in the System
# keychain needs a window server to present its authorization prompt, which SSH
# sessions don't have (fails "no user interaction was possible" on macOS 26).
#
# It does the two privileged, GUI-only steps test-safari.sh can't do headlessly:
#   1. Trusts the WPR ECDSA (P-256) root in the System keychain so Safari's TLS
#      validation passes when routed through WPR. Only the ECDSA root is trusted:
#      the bundled RSA root is 1024-bit, which Apple's TLS rejects outright
#      ("illegal parameter" handshake failure), so test-safari.sh serves ECDSA-only.
#   2. Enables safaridriver remote automation, which test-safari.sh drives.
#
# Idempotent: re-trusting an already-trusted cert is harmless; re-enabling
# safaridriver is a no-op. Re-run it any time the WPR certs are regenerated.
#
# After this runs once, every future run over SSH works unattended with NO sudo:
#   ssh crossbench.lan '.../test-safari.sh --sites wikipedia.org --reps 3 --yes'
set -euo pipefail

CROSSBENCH_DIR="${CROSSBENCH_DIR:-$HOME/Developer/crossbench-upstream}"
WPR_CERT_DIR="${WPR_CERT_DIR:-$CROSSBENCH_DIR/third_party/webpagereplay}"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

ECDSA_CERT="$WPR_CERT_DIR/ecdsa_cert.pem"

log() { echo "commission-safari: $*"; }
die() { echo "commission-safari: ERROR: $*" >&2; exit 1; }

# Refuse to run over SSH: the keychain-trust prompt can't be shown there, so trust
# would silently fail. SSH_CONNECTION / SSH_TTY are set only for remote sessions.
if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then
  die "run this from the VM's GUI Terminal, not over SSH (keychain trust needs the window server)."
fi

[ -f "$ECDSA_CERT" ] || die "ECDSA cert not found: $ECDSA_CERT (is CROSSBENCH_DIR right?)"

log "trusting the WPR ECDSA root in the System keychain (you'll be asked to authorize)..."
sudo security add-trusted-cert -d -r trustRoot -k "$SYSTEM_KEYCHAIN" "$ECDSA_CERT"

log "enabling safaridriver remote automation..."
sudo safaridriver --enable

log "verifying trust..."
if sudo security dump-trust-settings -d 2>/dev/null | grep -q "WebPerf"; then
  log "OK: WPR ECDSA root present in the System keychain trust settings."
else
  log "WARNING: could not confirm the WPR root in trust settings — check manually with:"
  log "  sudo security dump-trust-settings -d"
fi

log "done."
log "If safaridriver sessions still fail, enable Safari > Develop > Allow Remote"
log "Automation once (GUI checkbox), then re-run this script."
