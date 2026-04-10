---
name: ddg-vm-debug
description: Sign, notarize, and deploy macOS debug builds to VirtualBuddy VMs. Use this skill whenever the user wants to test a debug build on a VM, re-sign an app with Developer ID, notarize a build, deploy a build to a VM, or says things like "send the build to the VM", "notarize this", "sign for VM", "push to VM". Also trigger when there are code signing errors on a VM, provisioning profile issues, or entitlement mismatches.
---

# Deploy macOS Debug Builds to VMs

Sign Xcode debug builds with Developer ID, notarize, and deploy to VirtualBuddy VMs. This is necessary because debug builds use Apple Development signing which is device-specific and won't run on VMs without re-signing.

**Do NOT try to override CODE_SIGN_IDENTITY at build time** — Developer ID provisioning profiles don't exist for debug bundle IDs. Build normally with Xcode, then re-sign the output.

## Scripts

All heavy lifting is in scripts alongside this skill. Use `$SKILL_DIR` to locate them:

```bash
SKILL_DIR="$(dirname "$(find .claude/skills/ddg-vm-debug -name SKILL.md)")"
```

### sign-for-vm.sh — Sign & prepare for notarization

Extracts entitlements, fixes for Developer ID, finds & embeds correct provisioning profiles, signs inner-to-outer, verifies, and zips.

```bash
bash "$SKILL_DIR/sign-for-vm.sh" /Applications/DEBUG/DuckDuckGo.app
```

One command. Outputs `/tmp/DuckDuckGo.zip` ready for notarization.

### Notarize (always manual)

**Never attempt `notarytool submit` yourself** — credentials are interactive. Prompt the user:

```
Run this to notarize:
  ! xcrun notarytool submit /tmp/DuckDuckGo.zip --apple-id "YOUR_ID" --team-id "HKE973VLUW" --password "APP_PASSWORD" --wait

Then staple:
  ! xcrun stapler staple /Applications/DEBUG/DuckDuckGo.app
```

### deploy-to-vm.sh — Transfer & launch on VM

Tars (preserving symlinks), transfers via scp, extracts, verifies signature, and attempts launch.

```bash
bash "$SKILL_DIR/deploy-to-vm.sh" VM_USER VM_IP [APP_PATH] [SSH_KEY]
# Example:
bash "$SKILL_DIR/deploy-to-vm.sh" anh 192.168.64.6
```

## Full Workflow (3 steps)

1. **Sign**: `bash "$SKILL_DIR/sign-for-vm.sh"`
2. **Notarize**: Prompt user to run manually, then staple
3. **Deploy**: `bash "$SKILL_DIR/deploy-to-vm.sh" USER IP`

## Troubleshooting

### App gets killed immediately on VM (AMFI)
```bash
ssh -i ~/.ssh/vm_key USER@IP 'log show --last 30s --predicate "eventMessage CONTAINS \"AMFI\"" --style compact'
```
- **"No matching profile found"** — wrong profile type embedded. The sign script filters by `ProvisionsAllDevices=true` to pick Developer ID profiles, not Development.
- **"Unsatisfied entitlements"** — `packet-tunnel-provider` vs `packet-tunnel-provider-systemextension` mismatch. The sign script handles this.
- **"Provisioning profile does not allow this device"** — Development profile was embedded instead of Developer ID.

### codesign --verify fails with "bundle format is ambiguous"
App was transferred with `scp -r` which breaks framework symlinks. The deploy script uses tar to avoid this.

### Launch fails over SSH
`open` over SSH may fail due to GUI session restrictions. Ask user to double-click on the VM desktop.

## Gotchas

- **scp -r breaks symlinks** — always use tar (deploy script handles this)
- **Sign inner-to-outer** — outer signature covers inner; sign script handles ordering
- **`--deep` is unreliable** — sign script signs each component individually with correct entitlements
- **New VM = new host key** — deploy script clears old keys automatically
- **Standalone binaries** (like dbp-mcp-server) can be scp'd directly — no symlinks to break
