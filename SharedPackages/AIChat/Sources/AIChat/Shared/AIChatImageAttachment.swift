//
//  AIChatImageAttachment.swift
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

import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Represents an image attachment in the AI Chat interface.
public struct AIChatImageAttachment: Identifiable {
    public let id: UUID
    public let fileName: String
    public let fileURL: URL?

    #if os(macOS)
    public let image: NSImage

    public init(id: UUID = UUID(), image: NSImage, fileName: String, fileURL: URL? = nil) {
        self.id = id
        self.image = image
        self.fileName = fileName
        self.fileURL = fileURL
    }
    #elseif os(iOS)
    public let image: UIImage

    public init(id: UUID = UUID(), image: UIImage, fileName: String, fileURL: URL? = nil) {
        self.id = id
        self.image = image
        self.fileName = fileName
        self.fileURL = fileURL
    }
    #endif
}
