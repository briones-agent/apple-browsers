//
//  PasteboardAttachmentReaderTests.swift
//  DuckDuckGoTests
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
import UniformTypeIdentifiers
import XCTest
@testable import DuckDuckGo

@MainActor
final class PasteboardAttachmentReaderTests: XCTestCase {

    // MARK: - hasSupportedAttachments

    func testHasSupportedAttachmentsFindsImageWhenImagesAllowed() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.image = makeTestImage()

        XCTAssertTrue(PasteboardAttachmentReader.hasSupportedAttachments(
            in: pasteboard, allowsImages: true, allowedFileTypes: []
        ))
    }

    func testHasSupportedAttachmentsIgnoresImageWhenImagesNotAllowed() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.image = makeTestImage()

        XCTAssertFalse(PasteboardAttachmentReader.hasSupportedAttachments(
            in: pasteboard, allowsImages: false, allowedFileTypes: []
        ))
    }

    func testHasSupportedAttachmentsFindsFileMatchingAllowedType() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.itemProviders = [makePDFProvider()]

        XCTAssertTrue(PasteboardAttachmentReader.hasSupportedAttachments(
            in: pasteboard, allowsImages: false, allowedFileTypes: [.pdf]
        ))
    }

    func testHasSupportedAttachmentsRejectsFileNotInAllowedTypes() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.itemProviders = [makePDFProvider()]

        XCTAssertFalse(PasteboardAttachmentReader.hasSupportedAttachments(
            in: pasteboard, allowsImages: false, allowedFileTypes: [.plainText]
        ))
    }

    func testHasSupportedAttachmentsRejectsFileWhenNoTypesAllowed() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.itemProviders = [makePDFProvider()]

        XCTAssertFalse(PasteboardAttachmentReader.hasSupportedAttachments(
            in: pasteboard, allowsImages: true, allowedFileTypes: []
        ))
    }

    // MARK: - loadAttachments

    func testLoadAttachmentsLoadsImage() async {
        let provider = NSItemProvider(object: makeTestImage())
        provider.suggestedName = "snapshot"

        let result = await PasteboardAttachmentReader.loadAttachments(
            from: [provider], allowsImages: true, allowedFileTypes: []
        )

        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images.first?.fileName, "snapshot")
        XCTAssertTrue(result.files.isEmpty)
    }

    func testLoadAttachmentsSkipsImageWhenImagesNotAllowed() async {
        let provider = NSItemProvider(object: makeTestImage())

        let result = await PasteboardAttachmentReader.loadAttachments(
            from: [provider], allowsImages: false, allowedFileTypes: []
        )

        XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testLoadAttachmentsLoadsFileWithMimeAndExtension() async {
        let data = Data("%PDF-1.4 test".utf8)
        let provider = makePDFProvider(data: data, suggestedName: "report")

        let result = await PasteboardAttachmentReader.loadAttachments(
            from: [provider], allowsImages: false, allowedFileTypes: [.pdf]
        )

        XCTAssertEqual(result.files.count, 1)
        let file = try? XCTUnwrap(result.files.first)
        XCTAssertEqual(file?.mimeType, "application/pdf")
        XCTAssertEqual(file?.fileName, "report.pdf")
        XCTAssertEqual(file?.data, data)
        XCTAssertTrue(result.images.isEmpty)
    }

    func testLoadAttachmentsPrefersImageOverFileForImageProvider() async {
        let provider = NSItemProvider(object: makeTestImage())

        let result = await PasteboardAttachmentReader.loadAttachments(
            from: [provider], allowsImages: true, allowedFileTypes: [.image, .jpeg]
        )

        XCTAssertEqual(result.images.count, 1)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testLoadAttachmentsRejectsFileOverRemainingCountWithoutReading() async {
        let provider = makePDFProvider(data: Data("%PDF-1.4".utf8))

        let result = await PasteboardAttachmentReader.loadAttachments(
            from: [provider], allowsImages: false, allowedFileTypes: [.pdf], remainingFileCount: 0
        )

        XCTAssertEqual(result.files.count, 1)
        XCTAssertTrue(result.files.first?.data.isEmpty ?? false, "over-count file should not be read into memory")
    }

    func testLoadAttachmentsRejectsFileOverRemainingBytesWithoutReading() async {
        let data = Data("%PDF-1.4 larger than budget".utf8)
        let provider = makePDFProvider(data: data)

        let result = await PasteboardAttachmentReader.loadAttachments(
            from: [provider], allowsImages: false, allowedFileTypes: [.pdf], maxFileSizeBytes: 10_000, remainingTotalFileBytes: 4
        )

        XCTAssertEqual(result.files.count, 1)
        let file = result.files.first
        XCTAssertTrue(file?.data.isEmpty ?? false, "over-total file should not be read into memory")
        XCTAssertEqual(file?.fileSizeBytes, data.count, "sentinel keeps the real size so the policy rejects it")
    }

    func testLoadAttachmentsStopsReadingOnceBudgetExhausted() async {
        let data = Data("%PDF-1.4".utf8) // 8 bytes each
        let providers = [makePDFProvider(data: data, suggestedName: "a"), makePDFProvider(data: data, suggestedName: "b")]

        let result = await PasteboardAttachmentReader.loadAttachments(
            from: providers, allowsImages: false, allowedFileTypes: [.pdf], maxFileSizeBytes: 10_000, remainingTotalFileBytes: data.count
        )

        XCTAssertEqual(result.files.count, 2)
        XCTAssertFalse(result.files[0].data.isEmpty, "first file fits the budget and is read")
        XCTAssertTrue(result.files[1].data.isEmpty, "second file exceeds the remaining budget and is not read")
    }

    // MARK: - Helpers

    private func makeTestImage(size: CGSize = CGSize(width: 10, height: 10)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makePDFProvider(data: Data = Data("%PDF-1.4".utf8), suggestedName: String = "doc") -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}
