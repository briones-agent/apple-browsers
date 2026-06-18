//
//  ScreenshotCapture.swift
//
//  Copyright © 2026 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AppKit
import CoreGraphics
import os.log

/// Native screen capture for the Duck.ai omnibar attach menu. Shells out to
/// `/usr/sbin/screencapture` for three modes:
///
/// - `captureInteractiveRegion()` — `-i`, drag-to-select region (the macOS ⇧⌘4 UX).
/// - `captureScreen(index:)` — `-D <index>`, captures one whole display by 1-based index.
/// - `captureWindow(windowID:)` — `-l <id>`, captures one window by its `CGWindowID`.
///
/// **macOS App Sandbox**: this path is intended for the Sparkle / Debug variants only —
/// neither has the `com.apple.security.app-sandbox` entitlement (see
/// `DuckDuckGo.entitlements` / `DuckDuckGoDebug.entitlements`). The App Store build is
/// sandboxed and cannot launch `/usr/sbin/screencapture`; callers gate visibility at the
/// menu site via `AppVersion.isAppStoreBuild`. A ScreenCaptureKit follow-up will close that
/// gap. The dependency on `Process` is consistent with `DockCustomizer`, `LogExporter`,
/// and `NetworkProtectionDiagnosticsExporter`, which all shell out today.
///
/// **Permission**: every variant requires Screen Recording (TCC) in macOS 13+. The first
/// call to `CGRequestScreenCaptureAccess()` surfaces the system prompt; subsequent calls
/// return the current state without re-prompting. After the user grants the permission a
/// relaunch is required before capture starts working — that's a macOS-level requirement.
enum ScreenshotCapture {

    private static let logger = Logger(subsystem: "Duck.ai Omnibar", category: "Screenshot")

    /// One available display the user can target from the screenshot submenu.
    ///
    /// `index` is 1-based — exactly what `screencapture -D` expects. The man page wording calls
    /// this a "display id" but in practice newer macOS versions treat the value as a 1-based
    /// position in the list of attached displays (1 = main, 2 = secondary, …); passing the
    /// `CGDirectDisplayID` silently no-ops because the id is well outside the [1, n] range.
    struct ScreenInfo: Hashable {
        let index: Int
        let name: String
    }

    /// One on-screen window the user can target from the screenshot submenu.
    struct WindowInfo: Hashable {
        let windowID: CGWindowID
        let appName: String
        let windowTitle: String
        let icon: NSImage?

        /// Combined human-readable label for the menu: `App — Window Title`, or just the app
        /// name when the title is empty (some apps don't set window titles).
        var menuTitle: String {
            windowTitle.isEmpty ? appName : "\(appName) — \(windowTitle)"
        }
    }

    // MARK: - Capture

    /// Drag-to-select region capture (system overlay handles the UI).
    @MainActor
    static func captureInteractiveRegion() async -> NSImage? {
        await runCapture(arguments: ["-i", "-o", "-t", "png", "-x"])
    }

    /// Captures the entire display at the given 1-based index (1 = main display).
    @MainActor
    static func captureScreen(index: Int) async -> NSImage? {
        await runCapture(arguments: ["-D", String(index), "-o", "-t", "png", "-x"])
    }

    /// Captures the window identified by `windowID` (a `kCGWindowNumber`).
    @MainActor
    static func captureWindow(windowID: CGWindowID) async -> NSImage? {
        await runCapture(arguments: ["-l", String(windowID), "-o", "-t", "png", "-x"])
    }

    // MARK: - Enumeration

    /// All connected displays, in `NSScreen.screens` order (typically primary first). Indices
    /// are 1-based to match `screencapture -D`'s contract.
    static func availableScreens() -> [ScreenInfo] {
        NSScreen.screens.enumerated().map { offset, screen in
            let name: String
            if #available(macOS 14.0, *) {
                name = screen.localizedName
            } else if let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
                name = "Display \(raw)"
            } else {
                name = "Display \(offset + 1)"
            }
            return ScreenInfo(index: offset + 1, name: name)
        }
    }

    /// All normal app windows across every Space (current + other desktops), excluding our own
    /// app's windows and system chrome. Sorted by app name then window title for stable menu
    /// order.
    @MainActor
    static func availableWindows() -> [WindowInfo] {
        // Intentionally NOT using `.optionOnScreenOnly` — that restricts to windows visible on
        // the user's CURRENT Space, hiding everything on other desktops. Dropping it gives us
        // every window in every Space; `.excludeDesktopElements` still keeps wallpaper / Finder
        // icons out.
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        // `CGWindowListCopyWindowInfo` returns the window list regardless of permission, but
        // `kCGWindowName` (the title) only comes back populated when Screen Recording has been
        // granted. Pre-permission we'd otherwise drop every window via the empty-title filter
        // below and leave the user with an empty Windows section — frustrating, because they
        // can't see what they'd be granting permission FOR. Preflight here (no prompt) and
        // relax the title filter when permission isn't granted: the menu falls back to the
        // bare app name. After the user grants + relaunches, the full per-window titles take
        // over on subsequent menu opens.
        let hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        // Per-PID caches so we don't ask `NSRunningApplication` once per window.
        var iconCache: [Int32: NSImage?] = [:]
        var policyCache: [Int32: NSApplication.ActivationPolicy?] = [:]

        let windows: [WindowInfo] = rawList.compactMap { dict -> WindowInfo? in
            // No alpha filter — windows on inactive Spaces report `alpha == 0` even though
            // they're legitimately user-facing once the Space is switched. We rely on layer +
            // activation-policy + non-empty-title filters to drop chrome instead.
            guard let layerNumber = dict[kCGWindowLayer as String] as? Int,
                  layerNumber == 0,
                  let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let appName = dict[kCGWindowOwnerName as String] as? String,
                  let pid = dict[kCGWindowOwnerPID as String] as? Int32 else {
                return nil
            }

            // Skip windows owned by system services that never present a real UI to the user
            // (loginwindow, storeuid, AutoFill / Keychain popovers, "Open and Save Panel
            // Service", "User Notification Center", etc.). Two-layer filter:
            // 1. `NSApplication.activationPolicy == .prohibited` catches the headless ones.
            // 2. Apple's own helper agents often advertise as `.accessory` (LaunchServices
            //    treats them like menu-bar apps) — drop those by bundle prefix so the menu
            //    keeps third-party `.accessory` apps like Bartender / Mattermost that own
            //    real windows the user genuinely wants to screenshot.
            let runningApp = NSRunningApplication(processIdentifier: pid)
            let policy: NSApplication.ActivationPolicy?
            if let cached = policyCache[pid] {
                policy = cached
            } else {
                policy = runningApp?.activationPolicy
                policyCache[pid] = policy
            }
            guard let policy, policy != .prohibited else { return nil }
            if policy == .accessory,
               let bundleID = runningApp?.bundleIdentifier,
               bundleID.hasPrefix("com.apple.") {
                return nil
            }

            // Skip our own windows.
            if let ownBundleID,
               let app = NSRunningApplication(processIdentifier: pid),
               app.bundleIdentifier == ownBundleID {
                return nil
            }

            // Skip windows whose bounds are tiny (system chrome / off-screen scratchpads).
            if let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] {
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                if width < 80 || height < 80 {
                    return nil
                }
            }

            // Drop untitled windows ONLY when Screen Recording is granted — they're back-buffers
            // / splash frames / auxiliary surfaces in that case. Without permission, *every*
            // title comes back empty, and dropping them would yield an empty Windows section
            // (see comment up top); fall through with just the app name so the user has
            // something to click on to trigger the permission prompt.
            let title = dict[kCGWindowName as String] as? String ?? ""
            if hasScreenRecordingPermission, title.isEmpty {
                return nil
            }

            let icon: NSImage?
            if let cached = iconCache[pid] {
                icon = cached
            } else {
                let resolved = NSRunningApplication(processIdentifier: pid)?.icon
                iconCache[pid] = resolved
                icon = resolved
            }
            return WindowInfo(windowID: windowID, appName: appName, windowTitle: title, icon: icon)
        }

        // Pre-permission, every title comes back empty, so multiple windows of the same app
        // would render as identical menu rows. Collapse to one entry per app — first window
        // wins. Once permission is granted the user gets real titles and we keep them all.
        let deduped: [WindowInfo]
        if hasScreenRecordingPermission {
            deduped = windows
        } else {
            var seenApps = Set<String>()
            deduped = windows.filter { seenApps.insert($0.appName).inserted }
        }

        return deduped.sorted {
            if $0.appName == $1.appName {
                return $0.windowTitle.localizedCaseInsensitiveCompare($1.windowTitle) == .orderedAscending
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    // MARK: - Private

    @MainActor
    private static func runCapture(arguments: [String]) async -> NSImage? {
        guard CGRequestScreenCaptureAccess() else {
            logger.info("Screen Recording permission not granted — aborting capture.")
            return nil
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ddg-screenshot-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [tempURL.path]

        let exitCode: Int32 = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                Self.logger.error("Failed to launch /usr/sbin/screencapture: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: -1)
            }
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard exitCode == 0 else {
            logger.info("screencapture exited \(exitCode); treating as cancel.")
            return nil
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 0 else {
            return nil
        }

        guard let image = NSImage(contentsOf: tempURL) else {
            logger.error("Failed to load captured screenshot from \(tempURL.path, privacy: .public).")
            return nil
        }

        return image
    }
}
