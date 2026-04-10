#!/bin/bash
set -euo pipefail

# Sign a DuckDuckGo debug build with Developer ID for VM deployment.
# Extracts entitlements, fixes for Developer ID, embeds provisioning profiles,
# signs inner-to-outer, verifies, and zips for notarization.
#
# Usage: sign-for-vm.sh [APP_PATH]
#   APP_PATH defaults to /Applications/DEBUG/DuckDuckGo.app

APP="${1:-/Applications/DEBUG/DuckDuckGo.app}"
SIGN="Developer ID Application: Duck Duck Go, Inc. (HKE973VLUW)"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

VPN="$APP/Contents/Library/LoginItems/DuckDuckGo VPN.app"
PIR="$APP/Contents/Library/LoginItems/DuckDuckGo Personal Information Removal.app"
SYSEX="$VPN/Contents/Library/SystemExtensions/com.duckduckgo.macos.vpn.network-extension.debug.systemextension"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

ZIP_OUT="/tmp/DuckDuckGo.zip"

# --- Helpers ---

find_devid_profile() {
  local target_id="$1" best="" best_date="1970-01-01"
  for f in "$PROFILES_DIR"/*.provisionprofile; do
    decoded=$(security cms -D -i "$f" 2>/dev/null) || continue
    all=$(echo "$decoded" | plutil -extract ProvisionsAllDevices raw - 2>/dev/null)
    [ "$all" != "1" ] && [ "$all" != "true" ] && continue
    appid=$(echo "$decoded" | plutil -extract 'Entitlements.com\.apple\.application-identifier' raw - 2>/dev/null)
    stripped="${appid#*.}"
    if [ "$stripped" = "$target_id" ]; then
      created=$(echo "$decoded" | plutil -extract CreationDate raw - 2>/dev/null)
      if [[ "$created" > "$best_date" ]]; then best="$f"; best_date="$created"; fi
    fi
  done
  [ -z "$best" ] && echo "ERROR: No Developer ID profile for $target_id" >&2 && return 1
  echo "$best"
}

sign_frameworks() {
  local dir="$1"
  for fw in "$dir"/*.framework; do [ -d "$fw" ] && codesign --force -o runtime --sign "$SIGN" "$fw"; done
  for dl in "$dir"/*.dylib; do [ -f "$dl" ] && codesign --force -o runtime --sign "$SIGN" "$dl"; done
}

# --- Step 1: Extract & fix entitlements ---

echo "=== Extracting entitlements ==="
codesign -d --xml --entitlements /tmp/main.plist "$APP"
codesign -d --xml --entitlements /tmp/vpn.plist "$VPN"
codesign -d --xml --entitlements /tmp/pir.plist "$PIR"
codesign -d --xml --entitlements /tmp/sysex.plist "$SYSEX"

for f in /tmp/main.plist /tmp/vpn.plist /tmp/pir.plist /tmp/sysex.plist; do
  plutil -convert xml1 "$f"
done

echo "=== Fixing entitlements for Developer ID ==="
for f in /tmp/main.plist /tmp/vpn.plist /tmp/pir.plist /tmp/sysex.plist; do
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$f" 2>/dev/null || true
done

for f in /tmp/main.plist /tmp/vpn.plist /tmp/sysex.plist; do
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.networking.networkextension:0 packet-tunnel-provider-systemextension" "$f" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.networking.networkextension:1 app-proxy-provider-systemextension" "$f" 2>/dev/null || true
done

# --- Step 2: Find & embed Developer ID profiles ---

echo "=== Finding Developer ID profiles ==="
MAIN_P=$(find_devid_profile "com.duckduckgo.macos.browser.debug")
VPN_P=$(find_devid_profile "com.duckduckgo.macos.vpn.debug")
PIR_P=$(find_devid_profile "com.duckduckgo.macos.DBP.backgroundAgent.debug")
SYSEX_P=$(find_devid_profile "com.duckduckgo.macos.vpn.network-extension.debug")

echo "  Main:  $(basename "$MAIN_P")"
echo "  VPN:   $(basename "$VPN_P")"
echo "  PIR:   $(basename "$PIR_P")"
echo "  SysEx: $(basename "$SYSEX_P")"

echo "=== Embedding profiles ==="
cp "$MAIN_P"  "$APP/Contents/embedded.provisionprofile"
cp "$VPN_P"   "$VPN/Contents/embedded.provisionprofile"
cp "$PIR_P"   "$PIR/Contents/embedded.provisionprofile"
cp "$SYSEX_P" "$SYSEX/Contents/embedded.provisionprofile"

# --- Step 3: Sign inner-to-outer ---

echo "=== Signing (inner to outer) ==="

# Sparkle
codesign --force -o runtime --sign "$SIGN" "$SPARKLE/Versions/B/Autoupdate"
codesign --force -o runtime --sign "$SIGN" "$SPARKLE/Versions/B/Updater.app"
for xpc in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
  codesign --force -o runtime --sign "$SIGN" "$xpc"
done
codesign --force -o runtime --sign "$SIGN" "$SPARKLE"

# System extension
sign_frameworks "$SYSEX/Contents/Frameworks"
codesign --force -o runtime --sign "$SIGN" --entitlements /tmp/sysex.plist "$SYSEX"

# VPN
sign_frameworks "$VPN/Contents/Frameworks"
codesign --force -o runtime --sign "$SIGN" --entitlements /tmp/vpn.plist "$VPN"

# PIR
sign_frameworks "$PIR/Contents/Frameworks"
codesign --force -o runtime --sign "$SIGN" --entitlements /tmp/pir.plist "$PIR"

# Main app (skip Sparkle, already signed)
for fw in "$APP/Contents/Frameworks/"*.framework; do
  [ "$(basename "$fw")" = "Sparkle.framework" ] && continue
  [ -d "$fw" ] && codesign --force -o runtime --sign "$SIGN" "$fw"
done
for dl in "$APP/Contents/Frameworks/"*.dylib; do
  [ -f "$dl" ] && codesign --force -o runtime --sign "$SIGN" "$dl"
done
codesign --force -o runtime --sign "$SIGN" --entitlements /tmp/main.plist "$APP"

# --- Verify ---

echo "=== Verifying ==="
codesign --verify --deep --strict "$APP"

# --- Zip for notarization ---

echo "=== Zipping ==="
ditto -c -k --keepParent "$APP" "$ZIP_OUT"

echo ""
echo "Done. Zip ready at $ZIP_OUT"
echo ""
echo "Now run notarization manually:"
echo "  xcrun notarytool submit $ZIP_OUT --apple-id YOUR_ID --team-id HKE973VLUW --password APP_PASSWORD --wait"
echo ""
echo "Then staple:"
echo "  xcrun stapler staple $APP"
