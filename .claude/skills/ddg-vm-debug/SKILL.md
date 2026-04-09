---
name: ddg-vm-debug
description: Sign, notarize, and deploy macOS debug builds to VirtualBuddy VMs. Use this skill whenever the user wants to test a debug build on a VM, re-sign an app with Developer ID, notarize a build, deploy a build to a VM, or says things like "send the build to the VM", "notarize this", "sign for VM", "push to VM". Also trigger when there are code signing errors on a VM, provisioning profile issues, or entitlement mismatches.
---

# Deploy macOS Debug Builds to VMs

Sign Xcode debug builds with Developer ID, notarize, and deploy to VirtualBuddy VMs. This is necessary because debug builds use Apple Development signing which is device-specific and won't run on VMs without re-signing.

## Why This Is Needed

- Debug builds are signed with Apple Development certs (device-specific)
- VMs aren't registered devices in the developer portal
- Developer ID signing + notarization works on any Mac, including VMs
- AMFI enforces provisioning profiles for restricted entitlements

**Do NOT try to override CODE_SIGN_IDENTITY at build time** (e.g. `xcodebuild ... CODE_SIGN_IDENTITY="Developer ID Application"`). This fails because Developer ID provisioning profiles don't exist for the debug bundle IDs. Instead, build normally with Xcode, then re-sign the output.

## Step 1: Extract Entitlements (first time only — reuse after)

Extract from the local debug build, convert to XML, and fix for Developer ID:

```bash
APP="/Applications/DEBUG/DuckDuckGo.app"

codesign -d --xml --entitlements /tmp/main.plist "$APP"
codesign -d --xml --entitlements /tmp/vpn.plist "$APP/Contents/Library/LoginItems/DuckDuckGo VPN.app"
codesign -d --xml --entitlements /tmp/pir.plist "$APP/Contents/Library/LoginItems/DuckDuckGo Personal Information Removal.app"
codesign -d --xml --entitlements /tmp/sysex.plist "$APP/Contents/Library/LoginItems/DuckDuckGo VPN.app/Contents/Library/SystemExtensions/com.duckduckgo.macos.vpn.network-extension.debug.systemextension"

# Convert to XML
for f in /tmp/main.plist /tmp/vpn.plist /tmp/pir.plist /tmp/sysex.plist; do
  plutil -convert xml1 "$f"
done
```

### Fix entitlements for Developer ID

**Remove `get-task-allow`** (debug-only entitlement, rejected by notarization):
```bash
for f in /tmp/main.plist /tmp/vpn.plist /tmp/pir.plist /tmp/sysex.plist; do
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$f" 2>/dev/null
done
```

**Fix network extension values** (Developer ID profiles use `-systemextension` suffix):
```bash
for f in /tmp/main.plist /tmp/vpn.plist /tmp/sysex.plist; do
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.networking.networkextension:0 packet-tunnel-provider-systemextension" "$f" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.networking.networkextension:1 app-proxy-provider-systemextension" "$f" 2>/dev/null
done
```

## Step 2: Embed Provisioning Profiles

Developer ID provisioning profiles must be embedded in each component. Find the right profiles:

```bash
# List Developer ID profiles for debug bundle IDs
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile; do
  name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)
  if echo "$name" | grep -qi "Direct.*debug"; then
    echo "$name | $(basename "$f")"
  fi
done
```

Copy each profile as `embedded.provisionprofile` into the corresponding component's `Contents/` directory.

## Step 3: Sign (Inner to Outer, Hardened Runtime)

Each executable must be signed individually, innermost first. Signing an outer bundle invalidates inner signatures. `--deep` doesn't handle per-component entitlements — don't use it.

**Signing order:**
1. Sparkle sub-binaries (Autoupdate, Updater.app, XPC services)
2. System extension frameworks/dylibs, then the system extension itself (with entitlements)
3. VPN login item frameworks/dylibs, then the VPN app (with entitlements)
4. PIR login item frameworks/dylibs, then the PIR app (with entitlements)
5. Main app frameworks/dylibs, then the main app (with entitlements)

**Signing command pattern:**
```bash
SIGN="Developer ID Application: Duck Duck Go, Inc. (HKE973VLUW)"

# Frameworks/dylibs (no entitlements needed)
codesign --force -o runtime --sign "$SIGN" /path/to/*.framework
codesign --force -o runtime --sign "$SIGN" /path/to/*.dylib

# Apps/extensions (with entitlements)
codesign --force -o runtime --sign "$SIGN" --entitlements /tmp/component.plist /path/to/Component.app
```

Key flags:
- `-o runtime` — hardened runtime, required for notarization
- `--force` — replace existing signature
- `--entitlements` — only for app/extension bundles, not frameworks/dylibs
- `--timestamp` — included automatically when signing with Developer ID cert online, but if notarization complains about missing timestamps, add it explicitly

**Verify after signing:**
```bash
codesign --verify --deep --strict /Applications/DEBUG/DuckDuckGo.app
```

## Step 4: Notarize

```bash
# Zip (ditto preserves structure)
ditto -c -k --keepParent /Applications/DEBUG/DuckDuckGo.app /tmp/DuckDuckGo.zip

# Submit (user runs this manually with their credentials)
xcrun notarytool submit /tmp/DuckDuckGo.zip \
  --apple-id "APPLE_ID" --team-id "HKE973VLUW" \
  --password "APP_SPECIFIC_PASSWORD" --wait

# Staple
xcrun stapler staple /Applications/DEBUG/DuckDuckGo.app
```

If notarization fails, check the log:
```bash
xcrun notarytool log SUBMISSION_ID --apple-id "..." --team-id "..." --password "..."
```

Common failures:
- `get-task-allow` entitlement present — remove it (Step 1)
- Hardened runtime not enabled — use `-o runtime` flag
- Missing sub-component signatures — sign ALL executables including Sparkle helpers
- Entitlement mismatch — check profile capabilities match entitlements

## Step 5: Transfer to VM

**Always use tar, never `scp -r`** (scp breaks framework symlinks):

```bash
cd /Applications/DEBUG && tar czf /tmp/DuckDuckGo_vm.tar.gz DuckDuckGo.app
scp -i ~/.ssh/vm_key /tmp/DuckDuckGo_vm.tar.gz VM_USER@VM_IP:/tmp/
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'sudo mkdir -p /Applications/DEBUG && cd /Applications/DEBUG && sudo tar xzf /tmp/DuckDuckGo_vm.tar.gz && sudo xattr -cr /Applications/DEBUG/DuckDuckGo.app'
```

**Verify on VM:**
```bash
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'codesign --verify --deep --strict /Applications/DEBUG/DuckDuckGo.app'
```

**Launch on VM via SSH:**
```bash
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'open /Applications/DEBUG/DuckDuckGo.app'
```

## Gotchas

- **scp -r breaks symlinks** in .framework bundles — always tar
- **Entitlement values differ** between Development and Developer ID profiles (`packet-tunnel-provider` vs `packet-tunnel-provider-systemextension`)
- **Sign inner-to-outer** — outer signature covers inner signatures; if you re-sign outer, inner becomes invalid
- **`--deep` is unreliable** — it applies the same entitlements to everything; sign components individually
- **New VM = new host key** — `ssh-keygen -R VM_IP` before connecting
- **Standalone binaries** (like dbp-mcp-server) can be scp'd directly — no symlinks to break

## Troubleshooting

### App gets killed immediately on VM
Check system logs for AMFI errors:
```bash
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'log show --last 30s --predicate "eventMessage CONTAINS \"AMFI\" OR eventMessage CONTAINS \"unsatisfiedEntitlements\"" --style compact'
```
Common causes:
- **"No matching profile found"** — provisioning profile not embedded or doesn't match entitlements. Re-embed profiles (Step 2) and re-sign.
- **"Unsatisfied entitlements"** — entitlement values don't match what the profile allows. Check for the `packet-tunnel-provider` vs `packet-tunnel-provider-systemextension` mismatch (Step 1).
- **"Provisioning profile does not allow this device"** — wrong profile type. Must be Developer ID, not Development.

### codesign --verify fails with "bundle format is ambiguous"
The app was transferred with `scp -r` which breaks framework symlinks. Re-transfer using tar:
```bash
cd /Applications/DEBUG && tar czf /tmp/DuckDuckGo_vm.tar.gz DuckDuckGo.app
scp -i ~/.ssh/vm_key /tmp/DuckDuckGo_vm.tar.gz VM_USER@VM_IP:/tmp/
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'sudo rm -rf /Applications/DEBUG/DuckDuckGo.app && cd /Applications/DEBUG && sudo tar xzf /tmp/DuckDuckGo_vm.tar.gz'
```
