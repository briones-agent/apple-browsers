---
name: virtualbuddy
description: Manage VirtualBuddy macOS VMs — create, duplicate, trash, boot, stop, SSH into, and transfer files. Use this skill whenever the user mentions VirtualBuddy, macOS VMs, virtual machines for testing, spinning up a fresh VM, duplicating a VM, or needs to run something on a VM. Also trigger when the user says "new VM", "fresh VM", "reset VM", "trash the VM", or wants to SSH/transfer files to a VM.
---

# VirtualBuddy VM Management

Manage macOS VMs running in VirtualBuddy for testing and debugging.

## Prerequisites

Before doing anything, verify VirtualBuddy is installed:

```bash
ls /Applications/VirtualBuddy.app || ls ~/Applications/VirtualBuddy.app
```

If not installed, tell the user to install it from https://github.com/insidegui/VirtualBuddy and create a macOS VM before proceeding.

## VM Storage

VMs are `.vbvm` bundles stored at `~/Library/Application Support/VirtualBuddy/`. Each bundle contains:
- `.vbdata/Metadata.plist` — UUID, dates, install info
- `.vbdata/Config.plist` — hardware config (CPU, RAM, disk, network)
- `Disk.img` — boot disk
- `MachineIdentifier`, `HardwareModel` — identity files

## Booting and Stopping VMs

VirtualBuddy has deep links but they require the sending process to stay alive for authentication. The `open` command exits too fast and fails. Use `swift -e` with a RunLoop instead:

```bash
# Boot a VM
swift -e 'import AppKit; NSWorkspace.shared.open(URL(string: "virtualbuddy://boot?name=VM_NAME")!); RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))'

# Stop a VM
swift -e 'import AppKit; NSWorkspace.shared.open(URL(string: "virtualbuddy://stop?name=VM_NAME")!); RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))'
```

On first use, VirtualBuddy will show an authorization prompt — the user must approve it once. After that, subsequent deep links from the same process work automatically.

If deep links fail, fall back to asking the user to boot/stop from VirtualBuddy's UI.

## Duplicate a VM from Template

To create a fresh VM from a known-good template:

First, list available VMs to find the template:
```bash
ls "$HOME/Library/Application Support/VirtualBuddy/"*.vbvm
```

Look for a VM with "DUPLICATE", "template", or similar in the name. If no template is obvious, **ask the user** which VM to use as the base — don't guess.

Then duplicate using APFS clone (near-instant, space-efficient):
```bash
TEMPLATE_NAME="Tahoe SSH DUPLICATE THIS"  # adjust to actual template name
VM_DIR="$HOME/Library/Application Support/VirtualBuddy"
COPY_NAME="Test-$(date +%Y%m%d-%H%M%S)"

cp -Rc "$VM_DIR/$TEMPLATE_NAME.vbvm" "$VM_DIR/$COPY_NAME.vbvm"

# Generate new UUID
NEW_UUID=$(uuidgen)
/usr/libexec/PlistBuddy -c "Set :uuid $NEW_UUID" "$VM_DIR/$COPY_NAME.vbvm/.vbdata/Metadata.plist"
touch "$VM_DIR/$COPY_NAME.vbvm"
```

The VM appears in VirtualBuddy automatically. Boot it via the UI or deep link.

## Trash a VM

Move to macOS Trash (recoverable) — this matches VirtualBuddy's own behavior:

```bash
osascript -e "tell application \"Finder\" to delete POSIX file \"$HOME/Library/Application Support/VirtualBuddy/VMName.vbvm\""
```

**Never trash the template VM.** Before trashing, verify the VM name is not the template by checking it doesn't match the template name used for duplication. Only trash VMs that were duplicated from the template (e.g. names starting with `Test-`, `PIR-Debug-`, or `Copy of`).

**Stop the VM before trashing**, then tell the user to close the VM window — VirtualBuddy leaves the window open even after the VM is trashed.

## SSH Setup

### Prerequisites (on the VM)
1. Enable Remote Login: System Settings > General > Sharing > Remote Login
2. Get VM IP: `ifconfig | grep "inet "` — look for `192.168.64.x`

### Key-based auth (one-time, on host)

Replace `VM_USER` with the username on the VM and `VM_IP` with the IP from `ifconfig`.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/vm_key -N ""
ssh-copy-id -i ~/.ssh/vm_key VM_USER@VM_IP
```

### New VM host key
Each new VM has a different host key. Clear the old one before connecting:
```bash
ssh-keygen -R VM_IP
```

### Running commands
```bash
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'command here'
```

### Complex commands with special characters

Shell quoting over SSH is fragile — quotes, pipes, and special characters get mangled. For anything beyond a simple command, write a script locally, scp it, and execute it:

```bash
cat > /tmp/my_script.sh << 'SCRIPT'
#!/bin/bash
# Complex commands go here — no quoting issues
log show --last 5m --predicate 'process == "tccd" AND eventMessage CONTAINS "something"' --style compact
SCRIPT
scp -i ~/.ssh/vm_key /tmp/my_script.sh VM_USER@VM_IP:/tmp/
ssh -i ~/.ssh/vm_key VM_USER@VM_IP "bash /tmp/my_script.sh"
```

This avoids double-escaping hell and is more reliable than inline SSH commands.

## File Transfer

**Never use `scp -r` for app bundles** — it breaks framework symlinks.

### Sending files to VM (use tar)
```bash
tar czf /tmp/payload.tar.gz -C /source/dir FileOrFolder
scp -i ~/.ssh/vm_key /tmp/payload.tar.gz VM_USER@VM_IP:/tmp/
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'cd /destination && tar xzf /tmp/payload.tar.gz'
```

### Single files (scp is fine)
```bash
scp -i ~/.ssh/vm_key /path/to/file VM_USER@VM_IP:/destination/
```

## Common VM Prep (after duplicating from template)

The template VM should already have:
- Automatic login enabled
- Screen lock / password after screensaver disabled
- Remote Login enabled
- Xcode Command Line Tools installed (`xcode-select --install`)
- A known password

If starting from a completely fresh VM:
1. Set up user account and password
2. Enable automatic login: System Settings > Users & Groups > Automatic login > select user
3. Disable screen lock: System Settings > Lock Screen > set "Require password after screen saver begins or display is turned off" to **Never**
4. Disable screensaver: System Settings > Screen Saver > set to **Never**
5. Enable Remote Login: System Settings > General > Sharing > Remote Login
6. Install CLT: `xcode-select --install`
7. Get IP from `ifconfig`

These settings ensure the VM stays unlocked and accessible — no password prompts interrupting automated workflows or SSH sessions.
