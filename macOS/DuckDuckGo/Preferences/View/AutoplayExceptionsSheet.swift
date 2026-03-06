//
//  AutoplayExceptionsSheet.swift
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

import SwiftUI

struct AutoplayExceptionsSheet: View {

    @ObservedObject var autoplayModel: AutoplayPreferences
    @State private var isAddingDomain = false
    @State private var newDomain = ""
    @State private var newDomainMode: AutoplayBlockingMode = .allowAll
    @Environment(\.dismiss) private var dismiss

    private var sortedDomains: [String] {
        autoplayModel.exceptions.keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(UserText.autoplayExceptionsTitle)
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            if sortedDomains.isEmpty && !isAddingDomain {
                VStack {
                    Spacer()
                    Text(UserText.autoplayExceptionsEmpty)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(sortedDomains, id: \.self) { domain in
                        HStack {
                            Text(domain)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { autoplayModel.exceptions[domain] ?? .blockAudio },
                                set: { autoplayModel.exceptions[domain] = $0 }
                            )) {
                                ForEach(AutoplayBlockingMode.allCases, id: \.self) { mode in
                                    Text(mode.description).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()

                            Button {
                                autoplayModel.exceptions.removeValue(forKey: domain)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if isAddingDomain {
                        addDomainRow
                    }
                }
            }

            Divider()

            HStack {
                if !isAddingDomain {
                    Button(UserText.autoplayExceptionsAddWebsite) {
                        newDomain = ""
                        newDomainMode = .allowAll
                        isAddingDomain = true
                    }
                }
                Spacer()
                Button(UserText.autoplayExceptionsDone) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 360)
    }

    @ViewBuilder
    private var addDomainRow: some View {
        HStack {
            TextField(UserText.autoplayExceptionsDomainPlaceholder, text: $newDomain)
                .textFieldStyle(.roundedBorder)

            Picker("", selection: $newDomainMode) {
                ForEach(AutoplayBlockingMode.allCases, id: \.self) { mode in
                    Text(mode.description).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()

            Button(UserText.autoplayExceptionsAdd) {
                commitNewDomain()
            }
            .disabled(normalizedDomain.isEmpty)

            Button(UserText.autoplayExceptionsCancel) {
                isAddingDomain = false
            }
        }
    }

    private var normalizedDomain: String {
        var d = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
        if let range = d.range(of: "://") { d = String(d[range.upperBound...]) }
        d = d.components(separatedBy: "/").first ?? d
        return d
    }

    private func commitNewDomain() {
        let domain = normalizedDomain
        guard !domain.isEmpty else { return }
        autoplayModel.exceptions[domain] = newDomainMode
        isAddingDomain = false
        newDomain = ""
    }
}
