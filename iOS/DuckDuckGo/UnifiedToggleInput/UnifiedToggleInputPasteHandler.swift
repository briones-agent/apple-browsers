//
//  UnifiedToggleInputPasteHandler.swift
//  DuckDuckGo
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

import AIChat
import Core
import UIKit
import UniformTypeIdentifiers

/// Injected into the shared text controls so a native image/file paste is routed into the attachment strip; `nil` on non-UTI hosts leaves default text paste untouched.
@MainActor
protocol AttachmentPasteHandling: AnyObject {

    /// Whether the pasteboard holds image/file content that can become an attachment; metadata-only, safe from `canPerformAction(_:withSender:)`.
    func canPasteAttachments(from pasteboard: UIPasteboard) -> Bool

    /// Turns supported pasteboard items into attachments; loads asynchronously.
    func pasteAttachments(from pasteboard: UIPasteboard)
}

/// Shared `paste(_:)` / `canPerformAction(_:)` routing so the two text controls don't duplicate the logic.
@MainActor
enum AttachmentPasteRouting {

    static func canPaste(with handler: AttachmentPasteHandling?) -> Bool {
        handler?.canPasteAttachments(from: .general) ?? false
    }

    /// Routes the general pasteboard to the handler; returns `false` when the caller should fall back to the default paste.
    static func routePaste(with handler: AttachmentPasteHandling?) -> Bool {
        guard let handler, handler.canPasteAttachments(from: .general) else { return false }
        handler.pasteAttachments(from: .general)
        return true
    }
}

/// What the current model accepts, independent of remaining headroom, plus whether paste is enabled in the current state.
struct UnifiedToggleInputPasteSupport {
    let isEnabled: Bool
    let acceptsImages: Bool
    let fileTypes: [UTType]

    var acceptsAnyAttachment: Bool { acceptsImages || !fileTypes.isEmpty }
}

/// The host the paste handler calls back into to read limits and add/report attachments (the coordinator).
@MainActor
protocol UnifiedToggleInputPasteDelegate: AnyObject {
    var pasteAttachmentSupport: UnifiedToggleInputPasteSupport { get }
    func imageCapacityMessage() -> String?
    func pasteWillBeginExpandingIfNeeded()
    /// Adds the image if there is headroom; returns `false` when the image limit is reached.
    @discardableResult func addPastedImage(_ image: UIImage, fileName: String) -> Bool
    func addPastedFile(_ file: AIChatFileAttachment)
    func presentPasteError(_ message: String)
}

/// Owns the paste orchestration (gate → load → add → report) so the coordinator only supplies limits and add actions via `UnifiedToggleInputPasteDelegate`.
@MainActor
final class UnifiedToggleInputPasteHandler: AttachmentPasteHandling {

    weak var delegate: UnifiedToggleInputPasteDelegate?

    func canPasteAttachments(from pasteboard: UIPasteboard) -> Bool {
        guard let support = delegate?.pasteAttachmentSupport, support.isEnabled, support.acceptsAnyAttachment else { return false }
        return PasteboardAttachmentReader.hasSupportedAttachments(
            in: pasteboard,
            allowsImages: support.acceptsImages,
            allowedFileTypes: support.fileTypes
        )
    }

    func pasteAttachments(from pasteboard: UIPasteboard) {
        guard let delegate else { return }
        let support = delegate.pasteAttachmentSupport
        guard support.isEnabled, support.acceptsAnyAttachment else { return }
        let providers = pasteboard.itemProviders
        delegate.pasteWillBeginExpandingIfNeeded()
        Task { [weak self] in
            let result = await PasteboardAttachmentReader.loadAttachments(
                from: providers,
                allowsImages: support.acceptsImages,
                allowedFileTypes: support.fileTypes
            )
            self?.applyLoadedAttachments(result)
        }
    }

    /// Files are applied first so a rejected image's limit message (presented last) isn't cleared by a following successful file add.
    func applyLoadedAttachments(_ result: PasteboardAttachmentReader.Result) {
        guard let delegate else { return }

        for file in result.files {
            delegate.addPastedFile(file)
        }

        var didExceedLimit = false
        for image in result.images {
            guard delegate.addPastedImage(image.image, fileName: image.fileName) else {
                didExceedLimit = true
                break
            }
            DailyPixel.fireDailyAndCount(pixel: .unifiedToggleInputImageAttached, withAdditionalParameters: ["source": "paste"])
        }

        if didExceedLimit, let message = delegate.imageCapacityMessage() {
            delegate.presentPasteError(message)
        }
    }
}

/// Extracts image/file attachments from a `UIPasteboard`, mirroring the picker paths so pasted content flows through the same validation and UI as the attach menu.
@MainActor
enum PasteboardAttachmentReader {

    struct Result {
        var images: [(image: UIImage, fileName: String)] = []
        var files: [AIChatFileAttachment] = []
    }

    /// Metadata-only probe — inspects type identifiers without reading bytes, so it doesn't trigger the paste banner.
    static func hasSupportedAttachments(
        in pasteboard: UIPasteboard,
        allowsImages: Bool,
        allowedFileTypes: [UTType]
    ) -> Bool {
        if allowsImages, pasteboard.hasImages { return true }
        guard !allowedFileTypes.isEmpty else { return false }
        let identifiers = allowedFileTypes.map(\.identifier)
        return pasteboard.itemProviders.contains { provider in
            identifiers.contains { provider.hasItemConformingToTypeIdentifier($0) }
        }
    }

    /// Reads the pasteboard bytes (surfaces the banner) and builds attachments; file bytes are inspected off the main actor.
    static func loadAttachments(
        from providers: [NSItemProvider],
        allowsImages: Bool,
        allowedFileTypes: [UTType]
    ) async -> Result {
        var result = Result()
        for provider in providers {
            if allowsImages, provider.canLoadObject(ofClass: UIImage.self) {
                if let image = await loadImage(from: provider) {
                    result.images.append((image, provider.suggestedName ?? "image"))
                }
            } else if let type = allowedFileTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                if let file = await loadFile(from: provider, type: type) {
                    result.files.append(file)
                }
            }
        }
        return result
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    private static func loadFile(from provider: NSItemProvider, type: UTType) async -> AIChatFileAttachment? {
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }

        let baseName = provider.suggestedName ?? "file"
        let fileName = (baseName as NSString).pathExtension.isEmpty
            ? type.preferredFilenameExtension.map { "\(baseName).\($0)" } ?? baseName
            : baseName
        let mimeType = type.preferredMIMEType ?? "application/octet-stream"

        return await Task.detached(priority: .userInitiated) {
            UnifiedToggleInputAttachmentPresenter.makeFileAttachment(data: data, fileName: fileName, mimeType: mimeType)
        }.value
    }
}
