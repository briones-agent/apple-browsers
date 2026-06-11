//
//  WebView.swift
//
//  Copyright © 2020 DuckDuckGo. All rights reserved.
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

import Carbon.HIToolbox
import Cocoa
import Combine
import CommonObjCExtensions
import FeatureFlags
import ObjectiveC
import os.log
import PrivacyConfig
import WebKit

@MainActor
protocol WebViewContextMenuDelegate: AnyObject {
    func webView(_ webView: WebView, willOpenContextMenu menu: NSMenu, with event: NSEvent)
    func webView(_ webView: WebView, didCloseContextMenu menu: NSMenu, with event: NSEvent?)
}

enum WebViewInteractionEvent {
    case mouseDown(NSEvent)
    case middleMouseDown(NSEvent)
    case keyDown(NSEvent)
    case scrollWheel(NSEvent)
}

protocol WebViewZoomLevelDelegate: AnyObject {
    func zoomWasSet(to level: DefaultZoomValue)
}

@objc protocol WKInspectorDelegate {
    @MainActor @objc(inspector:openURLExternally:) optional func inspector(_ inspector: NSObject, openURLExternally url: NSURL?)
}

@objc(DuckDuckGo_WebView)
final class WebView: WKWebView {

    weak var contextMenuDelegate: WebViewContextMenuDelegate?
    weak var zoomLevelDelegate: WebViewZoomLevelDelegate?

    let interactionEventsPublisher = PassthroughSubject<WebViewInteractionEvent, Never>()
    private let featureFlagger: FeatureFlagger
    private let privacyConfig: PrivacyConfiguration

    private var isLoadingObserver: Any?
    /// used in tests
    @objc func resetLoadingObserver() {
        isLoadingObserver = nil
    }

    private var shouldShowWebInspector: Bool {
        // When a new tab is open, we don't want the web inspector to be active on screen and gain focus.
        // When a new tab is open the other tab views are removed from the window, hence, we should not show the web inspector.
        isInspectorShown && window != nil
    }

    /// Breakage Signals PoC — observes subresource load completions via WebKit SPI. See `BreakageResourceLoadObserver`.
    private(set) var breakageObserver: BreakageResourceLoadObserver?

    init(frame: CGRect = .zero,
         configuration: WKWebViewConfiguration = .init(),
         featureFlagger: FeatureFlagger,
         privacyConfig: PrivacyConfiguration = Application.appDelegate.privacyFeatures.contentBlocking.privacyConfigurationManager.privacyConfig) {
        self.featureFlagger = featureFlagger
        self.privacyConfig = privacyConfig

        _=Self.swizzleImmediateActionAnimationControllerOnce

        super.init(frame: frame, configuration: configuration)

        self.breakageObserver = BreakageResourceLoadObserver.attach(to: self) // Breakage Signals PoC
    }

    required init?(coder: NSCoder) {
        self.featureFlagger = Application.appDelegate.featureFlagger
        self.privacyConfig = Application.appDelegate.privacyFeatures.contentBlocking.privacyConfigurationManager.privacyConfig

        _=Self.swizzleImmediateActionAnimationControllerOnce

        super.init(coder: coder)
    }

    override func addTrackingArea(_ trackingArea: NSTrackingArea) {
        /// disable mouseEntered/mouseMoved/mouseExited events passing to Web View while it‘s loading
        /// see https://app.asana.com/0/1177771139624306/1206990108527681/f
        if trackingArea.owner?.className == "WKMouseTrackingObserver" {
            // suppress Tracking Area events while loading
            isLoadingObserver = self.observe(\.isLoading, options: [.new]) { [weak self, trackingArea] _, c in
                if c.newValue /* isLoading */ ?? false {
                    guard let self, self.trackingAreas.contains(trackingArea) else { return }
                    removeTrackingArea(trackingArea)
                } else {
                    guard let self, !self.trackingAreas.contains(trackingArea) else { return }
                    superAddTrackingArea(trackingArea)
                }
            }
        }
        super.addTrackingArea(trackingArea)
    }

    private func superAddTrackingArea(_ trackingArea: NSTrackingArea) {
        super.addTrackingArea(trackingArea)
    }

    override var isInFullScreenMode: Bool {
        if #available(macOS 13.0, *) {
            return self.fullscreenState != .notInFullscreen
        } else {
            return self.tabContentView !== self
        }
    }

    func stopAllMedia(shouldStopLoading: Bool) {
        if shouldStopLoading {
            stopLoading()
        }
        stopMediaCapture()
        stopAllMediaPlayback()
        if isInFullScreenMode {
            fullscreenWindowController?.window?.toggleFullScreen(self)
        }
        if isInspectorShown {
            closeDeveloperTools()
        }
    }

    deinit {
        self.configuration.userContentController.removeAllUserScripts()
    }

    // MARK: - Zoom

    var defaultZoomValue: DefaultZoomValue = .percent100

    var zoomLevel: DefaultZoomValue {
        get {
            return DefaultZoomValue(rawValue: pageZoom) ?? .percent100
        }
        set {
            pageZoom = newValue.rawValue
        }
    }

    var canZoomToActualSize: Bool {
        window != nil && zoomLevel != defaultZoomValue && !self.isInFullScreenMode
    }

    var canResetMagnification: Bool {
        window != nil && magnification != 1
    }

    var canZoomIn: Bool {
        window != nil && zoomLevel.index < DefaultZoomValue.allCases.count - 1 && !self.isInFullScreenMode
    }

    var canZoomOut: Bool {
        window != nil && zoomLevel.index > 0 && !self.isInFullScreenMode
    }

    func resetZoomLevel() {
        magnification = 1
        zoomLevel = defaultZoomValue
        zoomLevelDelegate?.zoomWasSet(to: zoomLevel)
    }

    func zoomIn() {
        // if displaying PDF
        if let pdfHudView = self.hudView() {
            pdfHudView.zoomIn()
            return
        }
        guard canZoomIn else { return }
        zoomLevel = DefaultZoomValue.allCases[self.zoomLevel.index + 1]
        zoomLevelDelegate?.zoomWasSet(to: zoomLevel)
    }

    func zoomOut() {
        // if displaying PDF
        if let pdfHudView = self.hudView() {
            pdfHudView.zoomOut()
            return
        }
        guard canZoomOut else { return }
        zoomLevel = DefaultZoomValue.allCases[self.zoomLevel.index - 1]
        zoomLevelDelegate?.zoomWasSet(to: zoomLevel)
    }

    // MARK: - Immediate Actions (Look Up)

    /// Suppress link preview (which creates a WebView without tracker protection)
    /// while allowing Look Up, Data Detectors, and other immediate action types.
    /// See WKWebViewPrivate.h: return nil for default behavior, NSNull to disable entirely.
    @objc dynamic func swizzled_immediateActionAnimationController(forHitTestResult hitTestResult: AnyObject,
                                                                   withType type: UInt /* _WKImmediateActionType */,
                                                                   userData: AnyObject?) -> AnyObject? {
        guard featureFlagger.isFeatureOn(.webViewLookUpAction) else {
            return NSNull()
        }
        if type == _WKImmediateActionType.linkPreview.rawValue {
            return NSNull()
        }
        return nil
    }

    static private let swizzleImmediateActionAnimationControllerOnce: () = {
        guard let originalMethod = class_getInstanceMethod(WebView.self, Selector.immediateActionAnimationController),
              let swizzledMethod = class_getInstanceMethod(WebView.self, #selector(swizzled_immediateActionAnimationController(forHitTestResult:withType:userData:)))
        else {
            assertionFailure("Methods not available")
            return
        }

        // Ensure the original selector exists on WebView itself before swizzling so we don't mutate WKWebView globally.
        let didAddOriginalMethod = class_addMethod(WebView.self,
                                                   Selector.immediateActionAnimationController,
                                                   method_getImplementation(originalMethod),
                                                   method_getTypeEncoding(originalMethod))
        guard didAddOriginalMethod,
              let webViewOriginalMethod = class_getInstanceMethod(WebView.self, Selector.immediateActionAnimationController) else {
            assertionFailure("Failed to add original method to WebView")
            return
        }

        method_exchangeImplementations(webViewOriginalMethod, swizzledMethod)
    }()

    // MARK: - Menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        contextMenuDelegate?.webView(self, willOpenContextMenu: menu, with: event)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextMenuDelegate?.webView(self, didCloseContextMenu: menu, with: event)
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        if shouldApplyControlClickFix(for: event),
            let modifierReleased  = NSEvent.keyEvent(with: .flagsChanged,
                                                location: event.locationInWindow,
                                                modifierFlags: event.modifierFlags.subtracting(.control),
                                                timestamp: event.timestamp,
                                                windowNumber: event.windowNumber,
                                                context: nil,
                                                characters: "",
                                                charactersIgnoringModifiers: "",
                                                isARepeat: false,
                                                keyCode: UInt16(kVK_Control)) {
            // Google Drive sometimes handles ctrl+click incorrectly: it extends selection instead of opening the context menu.
            // Simulate Control key release first, then forward the original ctrl+click so the page treats it as a right click.
            NSApp.sendEvent(modifierReleased)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                super.mouseDown(with: event)
            }
            return
        }

        super.mouseDown(with: event)
        interactionEventsPublisher.send(.mouseDown(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        if case .middle = event.button {
            interactionEventsPublisher.send(.middleMouseDown(event))
        }
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape,
           let window,
           window.styleMask.contains(.fullScreen),
           let fullscreenController {
            fullscreenController.handleEscapePress(host: url?.host)
        }

        super.keyDown(with: event)
        interactionEventsPublisher.send(.keyDown(event))
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        interactionEventsPublisher.send(.scrollWheel(event))
    }

    // MARK: - Developer Tools

    var inspectorDelegate: WKInspectorDelegate? {
        get {
            inspectorPerform("delegate")?.takeUnretainedValue() as? WKInspectorDelegate
        }
        set {
            inspectorPerform("setDelegate:", with: newValue)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if shouldShowWebInspector {
            openDeveloperTools()
        }
    }

    @nonobjc var mainFrame: AnyObject? {
        guard self.responds(to: NSSelectorFromString("_mainFrame")) else {
            assertionFailure("WKWebView does not respond to _mainFrame")
            return nil
        }
        return self.perform(NSSelectorFromString("_mainFrame"))?.takeUnretainedValue()
    }

    @discardableResult
    private func inspectorPerform(_ selectorName: String, with object: Any? = nil) -> Unmanaged<AnyObject>? {
        guard self.responds(to: NSSelectorFromString("_inspector")),
              let inspector = self.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: NSSelectorFromString(selectorName)) else {
            assertionFailure("_WKInspector does not respond to \(selectorName)")
            return nil
        }
        return inspector.perform(NSSelectorFromString(selectorName), with: object)
    }

    var isInspectorShown: Bool {
        return inspectorPerform("isVisible") != nil
    }

    @nonobjc func openDeveloperTools() {
        inspectorPerform("show")
    }

    @nonobjc func closeDeveloperTools() {
        inspectorPerform("close")
    }

    @nonobjc func openJavaScriptConsole() {
        inspectorPerform("showConsole")
    }

    @nonobjc func showPageSource() {
        guard let mainFrameHandle = self.mainFrame else { return }
        inspectorPerform("showMainResourceForFrame:", with: mainFrameHandle)
    }

    @nonobjc func showPageResources() {
        inspectorPerform("showResources")
    }

    // MARK: - Fullscreen

    /// actual view to be displayed as a Tab content
    /// may be the WebView itself or FullScreen Placeholder view
    var tabContentView: NSView {
        return fullScreenPlaceholderView ?? self
    }

    var fullscreenWindowController: NSWindowController? {
        guard let fullscreenWindowController = self.window?.windowController,
              fullscreenWindowController.className.contains("FullScreen")
        else {
            return nil
        }
        return fullscreenWindowController
    }

    var fullscreenController: FullscreenController? {
        return (window?.windowController as? MainWindowController)?.fullscreenController
    }

    // MARK: - NSDraggingDestination

    override func draggingUpdated(_ draggingInfo: NSDraggingInfo) -> NSDragOperation {
        if draggingInfo.draggingSource is WebView {
            return super.draggingUpdated(draggingInfo)
        }
        if NSApp.isCommandPressed || NSApp.isOptionPressed {
            return superview?.draggingUpdated(draggingInfo) ?? .none
        }

        let dragOperation = super.draggingUpdated(draggingInfo)
        guard dragOperation == .none,
              let superview else {
            return dragOperation
        }

        return superview.draggingUpdated(draggingInfo)
    }

    override func performDragOperation(_ draggingInfo: NSDraggingInfo) -> Bool {
        if draggingInfo.draggingSource is WebView {
            return super.performDragOperation(draggingInfo)
        }
        if NSApp.isCommandPressed || NSApp.isOptionPressed || super.draggingUpdated(draggingInfo) == .none {
            return superview?.performDragOperation(draggingInfo) ?? false
        }

        return super.performDragOperation(draggingInfo)
    }

    // MARK: - Find In Page

    enum FindResult: Error {
        case found(matches: UInt?)
        case notFound
        case cancelled
    }
    private var findInPageCompletionHandler: ((FindResult) -> Void)?

    @MainActor
    func find(_ string: String, with options: _WKFindOptions, maxCount: UInt) async -> FindResult {
        assert(!string.isEmpty)

        // native WKWebView find
        guard self.responds(to: Selector.findString) else {
            // fallback to official `findSting:`
            let config = WKFindConfiguration()
            config.backwards = options.contains(.backwards)
            config.caseSensitive = !options.contains(.caseInsensitive)
            config.wraps = options.contains(.wrapAround)

            return await withCheckedContinuation { continuation in
                self.find(string, configuration: config) { result in
                    continuation.resume(returning: result.matchFound ? .found(matches: nil) : .notFound)
                }
            }
        }

        _=Self.swizzleFindStringOnce

        // receive _WKFindDelegate calls and call completion handler
        NSException.try {
            self.setValue(self, forKey: "findDelegate")
        }
        if let findInPageCompletionHandler {
            self.findInPageCompletionHandler = nil
            findInPageCompletionHandler(.cancelled)
        }

        return await withCheckedContinuation { continuation in
            self.findInPageCompletionHandler = continuation.resume
            self.find(string, with: options.rawValue, maxCount: maxCount)
        }
    }

    static private let swizzleFindStringOnce: () = {
        guard let originalMethod = class_getInstanceMethod(WebView.self, Selector.findString),
              let swizzledMethod = class_getInstanceMethod(WebView.self, #selector(find(_:with:maxCount:)))
        else {
            assertionFailure("Methods not available")
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    // swizzled method to call `_findString:withOptions:maxCount:` without performSelector: usage (as there‘s 3 args)
    @objc dynamic private func find(_ string: String, with options: UInt, maxCount: UInt) {}

    func clearFindInPageState() {
        guard self.responds(to: Selector.hideFindUI) else {
            assertionFailure("_hideFindUI not available")
            return
        }
        self.perform(Selector.hideFindUI)
    }

    private enum Selector {
        static let findString = NSSelectorFromString("_findString:options:maxCount:")
        static let hideFindUI = NSSelectorFromString("_hideFindUI")
        static let immediateActionAnimationController = NSSelectorFromString("_immediateActionAnimationControllerForHitTestResult:withType:userData:")
    }

}
// MARK: - Find In Page
extension WebView /* _WKFindDelegate */ {

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFind matchesFound: UInt, for string: String, withMatchIndex _: Int) {
        if let findInPageCompletionHandler {
            self.findInPageCompletionHandler = nil
            findInPageCompletionHandler(.found(matches: matchesFound)) // matchIndex is broken in WebKit
        }
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFind string: String) {
        if let findInPageCompletionHandler {
            self.findInPageCompletionHandler = nil
            findInPageCompletionHandler(.notFound)
        }
    }

}

// MARK: - Control Click Fix
private extension WebView {

    struct ControlClickFixSettings: Decodable {
        let domains: [String]
    }

    enum ControlClickFixCache {
        static var domains: Set<String>?
        static var configIdentifier: String?
    }

    func shouldApplyControlClickFix(for event: NSEvent) -> Bool {
        guard case .left = event.button,
              event.modifierFlags.contains(.control),
              privacyConfig.isSubfeatureEnabled(MacOSBrowserConfigSubfeature.controlClickFix),
              let host = url?.host?.lowercased() else {
            return false
        }

        return configuredControlClickFixDomains.contains(host)
    }

    var configuredControlClickFixDomains: Set<String> {
        let currentIdentifier = privacyConfig.identifier

        if let cachedDomains = ControlClickFixCache.domains,
           let cachedIdentifier = ControlClickFixCache.configIdentifier,
           cachedIdentifier == currentIdentifier {
            return cachedDomains
        }

        guard let settingsString = privacyConfig.settings(for: MacOSBrowserConfigSubfeature.controlClickFix),
              let settingsData = settingsString.data(using: .utf8),
              let settings = try? JSONDecoder().decode(ControlClickFixSettings.self, from: settingsData) else {
            ControlClickFixCache.domains = []
            ControlClickFixCache.configIdentifier = currentIdentifier
            return []
        }

        let domains = Set(settings.domains.map { $0.lowercased() })
        ControlClickFixCache.domains = domains
        ControlClickFixCache.configIdentifier = currentIdentifier
        return domains
    }
}

// MARK: - Breakage Signals PoC
//
// Proof of concept for observing site-breakage signals on macOS via WebKit SPI.
// Logged to Console.app with the 🧪 marker (filter by "🧪"). Two signals:
//   1. Content-rule-list blocks — engine-truth, via `_WKContentRuleListAction`
//      (see DistributedNavigationDelegate, Navigation package).
//   2. Failed / errored subresources — via `_WKResourceLoadDelegate`, below.
// SPI types are read loosely via KVC so the PoC needs no WebKit private headers.

private enum BreakagePoCLog {
    static let logger = Logger(subsystem: "com.duckduckgo.macos.browser.breakage-poc", category: "BreakageSignalsPoC")
    static let marker = "🧪"
}

/// A single failed/errored subresource completion, forwarded to interested parties (e.g. `BreakageSignalsTabExtension`).
struct BreakageResourceObservation {
    let url: URL?
    let resourceTypeName: String
    let error: NSError?
    let httpStatusCode: Int?
}

/// Observes per-resource load completions. Set as the `_resourceLoadDelegate` on a WKWebView.
/// WebKit calls these via `respondsToSelector:`, so we don't need to declare conformance to the SPI protocol.
final class BreakageResourceLoadObserver: NSObject {

    private static var associatedKey: UInt8 = 0

    /// Invoked for each failed / errored subresource completion (successful loads are not forwarded).
    var onObservation: ((BreakageResourceObservation) -> Void)?

    /// Attaches a resource-load observer to a web view via the `_setResourceLoadDelegate:` SPI.
    /// The delegate property is weak, so we retain the observer as an associated object on the web view.
    @discardableResult
    static func attach(to webView: WKWebView) -> BreakageResourceLoadObserver? {
        let setter = NSSelectorFromString("_setResourceLoadDelegate:")
        guard webView.responds(to: setter) else {
            BreakagePoCLog.logger.error("\(BreakagePoCLog.marker, privacy: .public)❌ _setResourceLoadDelegate: unavailable — SPI not present")
            return nil
        }
        let observer = BreakageResourceLoadObserver()
        objc_setAssociatedObject(webView, &associatedKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.perform(setter, with: observer)
        BreakagePoCLog.logger.log("\(BreakagePoCLog.marker, privacy: .public)✅ attached resource-load observer")
        return observer
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func webView(_ webView: WKWebView,
                 resourceLoad: NSObject,
                 didCompleteWithError error: NSError?,
                 response: URLResponse?) {
        let url = resourceLoad.value(forKey: "originalURL") as? URL
        let urlString = url?.absoluteString ?? "<?>"
        let typeName = Self.resourceTypeName((resourceLoad.value(forKey: "resourceType") as? Int) ?? -1)
        let httpStatusCode = (response as? HTTPURLResponse)?.statusCode

        if let error {
            BreakagePoCLog.logger.error(
                "\(BreakagePoCLog.marker, privacy: .public)🛑 resource FAILED [\(typeName, privacy: .public)] code=\(error.code) \(error.domain, privacy: .public) — \(urlString, privacy: .public)")
        } else if let httpStatusCode, httpStatusCode >= 400 {
            BreakagePoCLog.logger.error(
                "\(BreakagePoCLog.marker, privacy: .public)⚠️ resource HTTP \(httpStatusCode) [\(typeName, privacy: .public)] — \(urlString, privacy: .public)")
        } else {
            // Successful 2xx/3xx loads are intentionally ignored — we only want breakage signal.
            return
        }

        onObservation?(BreakageResourceObservation(url: url, resourceTypeName: typeName, error: error, httpStatusCode: httpStatusCode))
    }

    private static func resourceTypeName(_ raw: Int) -> String {
        // Mirrors _WKResourceLoadInfoResourceType.
        switch raw {
        case 0: return "ApplicationManifest"
        case 1: return "Beacon"
        case 2: return "CSPReport"
        case 3: return "Document"
        case 4: return "Image"
        case 5: return "Fetch"
        case 6: return "Font"
        case 7: return "Media"
        case 8: return "Object"
        case 9: return "Ping"
        case 10: return "Script"
        case 11: return "Stylesheet"
        case 12: return "XMLHTTPRequest"
        case 13: return "XSLT"
        case -1: return "Other"
        default: return "Unknown(\(raw))"
        }
    }
}
