//
//  AIChatImageGalleryWidget.swift
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

import WidgetKit
import SwiftUI
import UIKit
import Core
import os.log

struct AIChatImageGalleryEntry: TimelineEntry {
    let date: Date
    let images: [WidgetImageEntry]
    let thumbnails: [String: UIImage]
    let isPreview: Bool

    /// Deep link that opens the chat that produced a given image.
    static func deepLink(forChatId chatId: String) -> URL {
        AIChatWidgetDeepLink.url(forChatId: chatId, source: WidgetSourceType.imageGalleryWidget.rawValue)
    }

    /// Deep link that opens a brand-new Duck.ai chat from the gallery's new-chat cell.
    static var newChatDeepLink: URL {
        DeepLinks.openAIChat.appendingParameter(name: WidgetSourceType.sourceKey,
                                                value: WidgetSourceType.imageGalleryWidget.rawValue)
    }
}

struct AIChatImageGalleryProvider: TimelineProvider {

    func placeholder(in context: Context) -> AIChatImageGalleryEntry {
        makeEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (AIChatImageGalleryEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AIChatImageGalleryEntry>) -> Void) {
        // The main app pushes reloads via WidgetCenter when the mirror changes; the periodic
        // policy is a fallback so the widget re-reads on its own even if a push is missed.
        let refresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [makeEntry()], policy: .after(refresh)))
    }

    private func makeEntry() -> AIChatImageGalleryEntry {
        // No flag gate here: the sync engine wipes the mirror when the setting is off, so
        // "no data on disk" is the safety guarantee. The widget just renders whatever exists.
        guard let location = AIChatWidgetDataLocation.appGroup() else {
            Logger.duckAiWidget.error("DUCKAI-WIDGET [ext/gallery] appGroup() returned nil")
            return AIChatImageGalleryEntry(date: Date(), images: [], thumbnails: [:], isPreview: false)
        }

        let images = (try? JSONDecoder().decode([WidgetImageEntry].self, from: Data(contentsOf: location.imagesFileURL))) ?? []

        var thumbnails: [String: UIImage] = [:]
        for image in images {
            if let data = try? Data(contentsOf: location.galleryImageURL(forImageId: image.imageId)),
               let uiImage = UIImage(data: data) {
                thumbnails[image.imageId] = Self.widgetReadyThumbnail(from: uiImage)
            }
        }

        let exists = FileManager.default.fileExists(atPath: location.imagesFileURL.path)
        let dir = (try? FileManager.default.contentsOfDirectory(atPath: location.rootURL.path)) ?? ["<read failed>"]
        Logger.duckAiWidget.notice("DUCKAI-WIDGET [ext/gallery] reads container=\(location.rootURL.path, privacy: .public) images.json exists=\(exists, privacy: .public) decoded=\(images.count, privacy: .public) thumbnails=\(thumbnails.count, privacy: .public) dir=[\(dir.joined(separator: ", "), privacy: .public)]")

        return AIChatImageGalleryEntry(date: Date(), images: images, thumbnails: thumbnails, isPreview: false)
    }

    /// Produces a small, fully-decoded **sRGB** bitmap sized for widget display.
    ///
    /// WidgetKit archives the rendered view to hand it to the widget host. An image that is too
    /// large, or wide-gamut / extended-range, can fail to archive — and the host then falls back to
    /// the redacted placeholder, so the view body renders with data but nothing shows. `toSRGB()` is
    /// unsuitable here: its default `UIGraphicsImageRendererFormat` inherits the screen scale (which
    /// triples the pixel count on a 3x device) and uses `preferredRange = .automatic` (producing a
    /// P3 / extended-range image on wide-gamut displays). This pins scale to 1, range to standard
    /// sRGB, and opaque to true, and downsamples to a widget-sized edge.
    private static func widgetReadyThumbnail(from image: UIImage, maxPixelEdge: CGFloat = 300) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height, 1)
        let scale = min(maxPixelEdge / longestEdge, 1)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

struct AIChatImageGalleryWidget: Widget {
    let kind: String = "AIChatImageGalleryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AIChatImageGalleryProvider()) { entry in
            AIChatImageGalleryWidgetView(entry: entry)
        }
        .configurationDisplayName(UserText.imageGalleryWidgetGalleryDisplayName)
        .description(UserText.imageGalleryWidgetGalleryDescription)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
