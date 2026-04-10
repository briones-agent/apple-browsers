#!/bin/bash
set -euo pipefail

# Deploy a signed DuckDuckGo build to a VirtualBuddy VM via SSH.
# Tars the app (preserving symlinks), transfers, extracts, verifies, and launches.
#
# Usage: deploy-to-vm.sh VM_USER VM_IP [APP_PATH] [SSH_KEY]
#   VM_USER   - SSH username on the VM
#   VM_IP     - VM IP address (usually 192.168.64.x)
#   APP_PATH  - defaults to /Applications/DEBUG/DuckDuckGo.app
#   SSH_KEY   - defaults to ~/.ssh/vm_key

VM_USER="${1:?Usage: deploy-to-vm.sh VM_USER VM_IP [APP_PATH] [SSH_KEY]}"
VM_IP="${2:?Usage: deploy-to-vm.sh VM_USER VM_IP [APP_PATH] [SSH_KEY]}"
APP="${3:-/Applications/DEBUG/DuckDuckGo.app}"
SSH_KEY="${4:-$HOME/.ssh/vm_key}"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new"
SSH="ssh $SSH_OPTS"
SCP="scp $SSH_OPTS"
TAR_FILE="/tmp/DuckDuckGo_vm.tar.gz"
REMOTE_DIR="/Applications/DEBUG"

# Clear old host key (new VM = new key)
ssh-keygen -R "$VM_IP" 2>/dev/null || true

echo "=== Creating tar (preserves symlinks) ==="
tar czf "$TAR_FILE" -C "$(dirname "$APP")" "$(basename "$APP")"
echo "  $(du -h "$TAR_FILE" | cut -f1)"

echo "=== Transferring to $VM_USER@$VM_IP ==="
$SCP "$TAR_FILE" "$VM_USER@$VM_IP:/tmp/"

echo "=== Extracting on VM ==="
$SSH "$VM_USER@$VM_IP" "mkdir -p $REMOTE_DIR && cd $REMOTE_DIR && tar xzf /tmp/DuckDuckGo_vm.tar.gz && xattr -cr $REMOTE_DIR/DuckDuckGo.app"

echo "=== Verifying signature on VM ==="
$SSH "$VM_USER@$VM_IP" "codesign --verify --deep --strict $REMOTE_DIR/DuckDuckGo.app"

echo "=== Launching ==="
$SSH "$VM_USER@$VM_IP" "open $REMOTE_DIR/DuckDuckGo.app" 2>/dev/null || \
  echo "Note: 'open' over SSH may fail on some macOS versions. Double-click the app on the VM desktop."

echo ""
echo "Done. App deployed to $VM_USER@$VM_IP:$REMOTE_DIR/DuckDuckGo.app"
