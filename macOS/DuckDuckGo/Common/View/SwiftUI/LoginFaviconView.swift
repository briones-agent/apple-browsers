//
//  LoginFaviconView.swift
//
//  Copyright © 2021 DuckDuckGo. All rights reserved.
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

import SwiftUI
import BrowserServicesKit
import SwiftUIExtensions

struct LoginFaviconView: View {
    let domain: String
    let generatedIconLetters: String
    let faviconManagement: FaviconManagement = NSApp.delegateTyped.faviconManager

    @State private var image: NSImage?

    private var displayableFaviconImage: NSImage? {
        faviconManagement.getCachedFaviconSafeForRendering(for: domain, sizeCategory: .small)?.image
    }

    private func refreshImage() {
        image = displayableFaviconImage
    }

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32)
                    .cornerRadius(4.0)
                    .padding(.leading, 6)
            } else {
                LetterIconView(title: generatedIconLetters, font: .system(size: 32, weight: .semibold))
                    .padding(.leading, 8)
            }
        }.onAppear {
            refreshImage()
        }.onReceive(NotificationCenter.default.publisher(for: .faviconCacheUpdated)) { note in
            // The favicon image may be decoded lazily after first appearance; re-read when the update
            // is relevant to this view's domain (or defensively if no payload is present).
            guard let update = note.faviconsCacheUpdate else {
                refreshImage()
                return
            }
            if update.hosts.contains(domain) {
                refreshImage()
            }
        }
    }

    var favicon: NSImage? {
        return displayableFaviconImage ?? .login
    }

}
