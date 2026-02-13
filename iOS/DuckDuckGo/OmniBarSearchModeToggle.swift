//
//  OmniBarSearchModeToggle.swift
//  DuckDuckGo
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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

import UIKit
import DesignResourcesKit
import DesignResourcesKitIcons

/// A pill-shaped toggle control for switching between Search and Duck.ai modes on iPad.
/// Displays two icon segments with a sliding indicator, matching the iOS phone pill toggle style.
final class OmniBarSearchModeToggle: UIControl {

    private enum Metrics {
        static let toggleWidth: CGFloat = 122
        static let toggleHeight: CGFloat = 35
        static let selectorInset: CGFloat = 2
        static let shadowRadius: CGFloat = 4
        static let shadowOffset = CGSize(width: 0, height: 2)
        static let shadowOpacity: Float = 0.12
        static let animationDuration: TimeInterval = 0.25
    }

    // MARK: - State

    private(set) var selectedMode: OmniBarSearchMode = .search

    // MARK: - Subviews

    private let backgroundPill = UIView()
    private let selectorView = UIView()
    private let searchIconView = UIImageView()
    private let aiChatIconView = UIImageView()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    func setMode(_ mode: OmniBarSearchMode, animated: Bool = false) {
        guard mode != selectedMode else { return }
        selectedMode = mode
        updateIcons()
        updateSelectorPosition(animated: animated)
    }

    // MARK: - Intrinsic size

    override var intrinsicContentSize: CGSize {
        CGSize(width: Metrics.toggleWidth, height: Metrics.toggleHeight)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        backgroundPill.frame = bounds
        backgroundPill.layer.cornerRadius = bounds.height / 2

        let selectorHeight = bounds.height - Metrics.selectorInset * 2
        selectorView.layer.cornerRadius = selectorHeight / 2

        updateSelectorPosition(animated: false)

        let halfWidth = bounds.width / 2
        searchIconView.frame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        aiChatIconView.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateColors()
        }
    }

    // MARK: - Private

    private func setup() {
        // Background pill
        backgroundPill.isUserInteractionEnabled = false
        addSubview(backgroundPill)

        // Selector pill
        selectorView.isUserInteractionEnabled = false
        selectorView.layer.shadowOffset = Metrics.shadowOffset
        selectorView.layer.shadowRadius = Metrics.shadowRadius
        selectorView.layer.shadowOpacity = Metrics.shadowOpacity
        addSubview(selectorView)

        // Icons
        searchIconView.contentMode = .center
        searchIconView.isUserInteractionEnabled = false
        addSubview(searchIconView)

        aiChatIconView.contentMode = .center
        aiChatIconView.isUserInteractionEnabled = false
        addSubview(aiChatIconView)

        updateColors()
        updateIcons()

        // Tap handling
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        // Fixed size
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.toggleWidth),
            heightAnchor.constraint(equalToConstant: Metrics.toggleHeight)
        ])
    }

    private func updateColors() {
        backgroundPill.backgroundColor = UIColor(designSystemColor: .backdrop)
        selectorView.backgroundColor = UIColor(designSystemColor: .surface)
        selectorView.layer.shadowColor = UIColor.black.cgColor
    }

    private func updateIcons() {
        let isSearch = selectedMode == .search
        searchIconView.image = isSearch
            ? DesignSystemImages.Glyphs.Size16.findSearchGradientColor
            : DesignSystemImages.Glyphs.Size16.findSearch
        aiChatIconView.image = isSearch
            ? DesignSystemImages.Glyphs.Size16.aiChat
            : DesignSystemImages.Glyphs.Size16.aiChatGradientColor
    }

    private func updateSelectorPosition(animated: Bool) {
        let selectorWidth = bounds.width / 2
        let selectorHeight = bounds.height - Metrics.selectorInset * 2
        let selectorX: CGFloat = selectedMode == .search
            ? Metrics.selectorInset
            : (bounds.width - selectorWidth - Metrics.selectorInset)
        let newFrame = CGRect(x: selectorX, y: Metrics.selectorInset,
                              width: selectorWidth, height: selectorHeight)

        guard animated else {
            selectorView.frame = newFrame
            return
        }

        UIView.animate(withDuration: Metrics.animationDuration, delay: 0, options: .curveEaseInOut) {
            self.selectorView.frame = newFrame
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        let newMode: OmniBarSearchMode = location.x < bounds.width / 2 ? .search : .duckAI
        guard newMode != selectedMode else { return }
        setMode(newMode, animated: true)
        sendActions(for: .valueChanged)
    }
}
