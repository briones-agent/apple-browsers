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
    /// Per-file byte limit, used to reject an oversized paste from its size alone before reading it into memory.
    let maxFileSizeBytes: Int?
    /// Remaining conversation file slots; the loader stops reading once exhausted so a large multi-file paste can't over-allocate.
    let remainingFileCount: Int?
    /// Remaining conversation file bytes; the loader reads only files that fit within this budget.
    let remainingTotalFileBytes: Int?

    init(
        isEnabled: Bool,
        acceptsImages: Bool,
        fileTypes: [UTType],
        maxFileSizeBytes: Int? = nil,
        remainingFileCount: Int? = nil,
        remainingTotalFileBytes: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.acceptsImages = acceptsImages
        self.fileTypes = fileTypes
        self.maxFileSizeBytes = maxFileSizeBytes
        self.remainingFileCount = remainingFileCount
        self.remainingTotalFileBytes = remainingTotalFileBytes
    }

    var acceptsAnyAttachment: Bool { acceptsImages || !fileTypes.isEmpty }
}

/// The host the paste handler calls back into to read limits and add/report attachments (the coordinator).
@MainActor
protocol UnifiedToggleInputPasteDelegate: AnyObject {
    var pasteAttachmentSupport: UnifiedToggleInputPasteSupport { get }
    /// Identity of the tab/surface the paste started on; the handler drops results if it changed during the async load.
    var pasteContextIdentity: String? { get }
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
        let context = delegate.pasteContextIdentity
        delegate.pasteWillBeginExpandingIfNeeded()
        Task { [weak self] in
            let result = await PasteboardAttachmentReader.loadAttachments(
                from: providers,
                allowsImages: support.acceptsImages,
                allowedFileTypes: support.fileTypes,
                maxFileSizeBytes: support.maxFileSizeBytes,
                remainingFileCount: support.remainingFileCount,
                remainingTotalFileBytes: support.remainingTotalFileBytes
            )
            self?.applyLoadedAttachments(result, expectedContext: context)
        }
    }

    /// Applied after the async load; drops the result if paste was disabled or the tab/surface changed during the load. Files first so a rejected image's limit message (presented last) survives a following file add.
    func applyLoadedAttachments(_ result: PasteboardAttachmentReader.Result, expectedContext: String? = nil) {
        guard let delegate,
              delegate.pasteAttachmentSupport.isEnabled,
              delegate.pasteContextIdentity == expectedContext else { return }

        for file in result.files {
            delegate.addPastedFile(file)
        }

        var didExceedLimit = false
        for image in result.images {
            guard delegate.addPastedImage(image.image, fileName: image.fileName) else {
                didExceedLimit = true
                break
            }
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

    /// Metadata-only probe (no byte reads, so no paste banner) that mirrors `loadAttachments`' per-provider classification, so a "yes" here means the loader will actually find something.
    static func hasSupportedAttachments(
        in pasteboard: UIPasteboard,
        allowsImages: Bool,
        allowedFileTypes: [UTType]
    ) -> Bool {
        let fileIdentifiers = allowedFileTypes.map(\.identifier)
        return pasteboard.itemProviders.contains { provider in
            if allowsImages, provider.canLoadObject(ofClass: UIImage.self) {
                return true
            }
            return fileIdentifiers.contains { provider.hasItemConformingToTypeIdentifier($0) }
        }
    }

    private enum LoadedFile {
        /// Bytes were read into memory; counts against the running budget.
        case read(AIChatFileAttachment)
        /// Rejected from metadata alone (per-file/total/count) without reading bytes; the policy surfaces the error.
        case rejected(AIChatFileAttachment)
    }

    /// Reads the pasteboard bytes (surfaces the banner) and builds attachments. Files are size/count-preflighted from
    /// metadata against the remaining budget so a large multi-file paste only ever loads what can actually be accepted.
    static func loadAttachments(
        from providers: [NSItemProvider],
        allowsImages: Bool,
        allowedFileTypes: [UTType],
        maxFileSizeBytes: Int? = nil,
        remainingFileCount: Int? = nil,
        remainingTotalFileBytes: Int? = nil
    ) async -> Result {
        var result = Result()
        var readFileCount = 0
        var readFileBytes = 0
        for provider in providers {
            if allowsImages, provider.canLoadObject(ofClass: UIImage.self) {
                if let image = await loadImage(from: provider) {
                    result.images.append((image, provider.suggestedName ?? "image"))
                }
            } else if let type = allowedFileTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                let loaded = await loadFile(
                    from: provider,
                    type: type,
                    maxFileSizeBytes: maxFileSizeBytes,
                    remainingCount: remainingFileCount.map { $0 - readFileCount },
                    remainingBytes: remainingTotalFileBytes.map { $0 - readFileBytes }
                )
                switch loaded {
                case .read(let file):
                    readFileCount += 1
                    readFileBytes += file.fileSizeBytes
                    result.files.append(file)
                case .rejected(let file):
                    result.files.append(file)
                case nil:
                    break
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

    /// Loads via a file representation and preflights per-file size, remaining count, and remaining total bytes from
    /// metadata; anything over budget becomes an empty-data attachment the policy rejects, so bytes are read only for
    /// files that can be accepted. `nil` limits mean files aren't offered at all, so a missing limit can't cause a read.
    private static func loadFile(
        from provider: NSItemProvider,
        type: UTType,
        maxFileSizeBytes: Int?,
        remainingCount: Int?,
        remainingBytes: Int?
    ) async -> LoadedFile? {
        let baseName = provider.suggestedName ?? "file"
        let fileName = (baseName as NSString).pathExtension.isEmpty
            ? type.preferredFilenameExtension.map { "\(baseName).\($0)" } ?? baseName
            : baseName
        let mimeType = type.preferredMIMEType ?? "application/octet-stream"

        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                func reject(size: Int) {
                    continuation.resume(returning: .rejected(AIChatFileAttachment(data: Data(), fileName: fileName, mimeType: mimeType, fileSizeBytes: size)))
                }

                if let remainingCount, remainingCount <= 0 {
                    reject(size: 0)
                    return
                }

                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let fileSize {
                    let overPerFile = maxFileSizeBytes.map { fileSize > $0 } ?? false
                    let overTotal = remainingBytes.map { fileSize > $0 } ?? false
                    if overPerFile || overTotal {
                        reject(size: fileSize)
                        return
                    }
                }

                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: .read(UnifiedToggleInputAttachmentPresenter.makeFileAttachment(data: data, fileName: fileName, mimeType: mimeType)))
            }
        }
    }
}
