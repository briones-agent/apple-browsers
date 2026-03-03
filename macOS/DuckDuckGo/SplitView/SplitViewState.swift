//
//  SplitViewState.swift
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
import Combine
import Foundation

/// Bundles the NSSplitView, pane views, and state for one split-view group.
final class SplitViewGroup {
    let state: SplitViewState
    let nsSplitView: NSSplitView
    var paneViews: [UUID: SplitPaneView] = [:]

    init(state: SplitViewState, nsSplitView: NSSplitView) {
        self.state = state
        self.nsSplitView = nsSplitView
    }

    /// Returns true if this group contains the given tab.
    func contains(tab: Tab) -> Bool {
        state.pane(for: tab) != nil
    }
}

/// Tracks the state of a split-screen browser view.
/// Each pane displays a separate tab side-by-side.
final class SplitViewState {

    struct Pane: Identifiable {
        let id: UUID
        let tab: Tab
        let tabViewModel: TabViewModel

        init(tab: Tab, tabViewModel: TabViewModel) {
            self.id = UUID()
            self.tab = tab
            self.tabViewModel = tabViewModel
        }
    }

    @Published private(set) var panes: [Pane]
    @Published var focusedPaneId: UUID

    var focusedPane: Pane? {
        panes.first { $0.id == focusedPaneId }
    }

    var focusedTabViewModel: TabViewModel? {
        focusedPane?.tabViewModel
    }

    var focusedTab: Tab? {
        focusedPane?.tab
    }

    var isSplitViewActive: Bool {
        panes.count > 1
    }

    init(panes: [Pane]) {
        assert(!panes.isEmpty, "SplitViewState must have at least one pane")
        self.panes = panes
        self.focusedPaneId = panes[0].id
    }

    func pane(for tab: Tab) -> Pane? {
        panes.first { $0.tab === tab }
    }

    func focusPane(at index: Int) {
        guard index >= 0, index < panes.count else { return }
        focusedPaneId = panes[index].id
    }

    func focusPane(withId id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPaneId = id
    }

    /// Append a new pane after the currently focused pane.
    @discardableResult
    func addPane(_ pane: Pane) -> Int {
        let insertionIndex: Int
        if let focusedIndex = panes.firstIndex(where: { $0.id == focusedPaneId }) {
            insertionIndex = focusedIndex + 1
        } else {
            insertionIndex = panes.count
        }
        panes.insert(pane, at: insertionIndex)
        return insertionIndex
    }

    /// Remove a pane by id. If the removed pane was focused, focus shifts to a neighbor.
    func removePane(withId id: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes.remove(at: index)
        if focusedPaneId == id, !panes.isEmpty {
            let newIndex = min(index, panes.count - 1)
            focusedPaneId = panes[newIndex].id
        }
    }
}
