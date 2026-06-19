//
//  TabSwitcherTransition.swift
//  DuckDuckGo
//
//  Copyright © 2017 DuckDuckGo. All rights reserved.
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
import Core
import os.log
import DesignResourcesKit
import DesignResourcesKitIcons
import UIComponents

class TabSwitcherTransition: NSObject, UIViewControllerAnimatedTransitioning {
    
    struct Constants {
        static let duration = 0.20
    }
    
    // Used to hide contents of the 'from' VC when animating.
    let solidBackground = UIView()
    // Container for the image, will clip subviews like tab switcher cell does.
    let imageContainer = UIView()
    // Image to display as a preview.
    let imageView = UIImageView()
    
    let tabSwitcherViewController: TabSwitcherViewController
    
    init(tabSwitcherViewController: TabSwitcherViewController) {
        self.tabSwitcherViewController = tabSwitcherViewController
    }
    
    func prepareSubviews(using transitionContext: UIViewControllerContextTransitioning) {
        
        transitionContext.containerView.addSubview(solidBackground)

        imageContainer.clipsToBounds = true
        imageContainer.addSubview(imageView)
        transitionContext.containerView.addSubview(imageContainer)
    }
    
    // MARK: UIViewControllerAnimatedTransitioning

    // Override - Abstract function
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        assertionFailure("You must implement this method")
    }
    
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return TabSwitcherTransition.Constants.duration
    }
    
    // MARK: Common logic
    
    func scrollIfOutsideViewport(collectionView: UICollectionView,
                                 rowIndex: Int,
                                 attributes: UICollectionViewLayoutAttributes) {
        // If cell is outside viewport, scroll while animating
        if attributes.frame.origin.y + attributes.frame.size.height < collectionView.contentOffset.y {
            collectionView.scrollToItem(at: IndexPath(row: rowIndex, section: 0),
                                        at: .top,
                                        animated: true)
        } else if attributes.frame.origin.y > collectionView.frame.height + collectionView.contentOffset.y {
            collectionView.scrollToItem(at: IndexPath(row: rowIndex, section: 0),
                                        at: .bottom,
                                        animated: true)
        }
    }
}

/// End-state and live references for the free-form swipe-up drag, produced by a `From*` transition's
/// `prepareInteractivePreview(...)` so `SwipeUpToTabSwitcherInteractiveTransition` can drive the same
/// page-preview card the button-tap keyframe path uses — sharing the exact destination-cell-frame math.
struct SwipeUpInteractivePreview {
    /// Hides the from-VC content; the controller inserts it at the bottom of the container view.
    let solidBackground: UIView
    /// The page-preview card the finger drags; transforms freely and snaps to `destinationCellFrame`.
    let imageContainer: UIView
    /// The preview image inside the card (web preview, or the NTP `.center` logo).
    let imageView: UIImageView
    /// NTP-only resizable snapshot that should fade out early to avoid the Dax-logo squeeze; nil for web.
    let homeScreenSnapshot: UIView?
    /// The all-tabs cell's top bar (favicon + title + X) replicated for the card. The controller adds it as
    /// a **sibling above `imageContainer`** (not a subview, so the NTP header can sit above the preview-only
    /// container too), starts it at alpha 0, fades it in with progress, tracks the card's top edge during the
    /// drag, and at commit snaps it to `destinationHeaderFrame` — pixel-matching the real cell's header.
    let cardHeader: SwipeUpCardHeaderView
    /// Full-content frame of `imageContainer` at progress 0 (where the page sits, minus the omnibar).
    let initialContainerFrame: CGRect
    /// Destination grid-cell frame `imageContainer` snaps to on commit (collection pre-scrolled to it).
    let destinationCellFrame: CGRect
    /// `imageView` frame inside the settled cell (web: `previewFrame`; NTP: centered logo frame).
    let destinationImageViewFrame: CGRect
    /// Absolute (tab-switcher-view space) `cardHeader` frame in the settled cell — the cell's top strip,
    /// full width, `cellHeaderHeight` tall — so it coincides exactly with the real cell's header on commit.
    let destinationHeaderFrame: CGRect
}

/// Live destination frames recomputed at commit (after the tracker-count banner has laid out), so the
/// card snaps onto the cell where it *now* sits rather than where it sat at gesture start.
struct SwipeUpDestinationFrames {
    let cell: CGRect
    let imageView: CGRect
    let header: CGRect
}

/// Implemented by the `From*` presentation animators so the interactive swipe-up controller can build
/// the dragged preview using their existing setup + cell-frame math instead of duplicating it.
protocol SwipeUpInteractiveTransition: AnyObject {
    /// Configures `solidBackground` + `imageContainer` (+ image / snapshot / logo / header) — frames,
    /// content, border colour — and pre-scrolls the tab switcher's collection to the current tab,
    /// returning the geometry the interaction controller drives. Does **not** add anything to the view
    /// hierarchy: the controller owns z-ordering (solidBackground at the bottom, then the overview +
    /// blur, then the card on top). Returns nil if the required tab/preview/layout isn't available.
    func prepareInteractivePreview(finalFrame: CGRect) -> SwipeUpInteractivePreview?

    /// Re-runs the cell-frame + preview/header math against the CURRENT collection-view layout, so the
    /// commit snap can target the cell where it now sits — the tracker-count banner is inserted as a
    /// section header *after* the gesture starts (pushing every cell down), which would otherwise make
    /// the card snap too high and jump when the snapshot is removed. Calls `layoutIfNeeded()` on the
    /// collection view first so a freshly-inserted banner is reflected. Returns nil if the tab/layout is
    /// no longer available (callers fall back to the frames captured at gesture start).
    func currentDestinationFrames() -> SwipeUpDestinationFrames?
}

class TabSwitcherTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {

    /// Non-nil only while an interactive swipe-up gesture is driving the presentation. The gesture
    /// owns the controller strongly; this weak reference lets ordinary button-tap presentations
    /// (where it stays nil) fall through to the normal, non-interactive animation unchanged. Typed as
    /// the base `UIViewControllerInteractiveTransitioning` so it can vend the custom finger-tracking
    /// controller (not just the old `UIPercentDrivenInteractiveTransition`).
    weak var activeInteractiveTransition: UIViewControllerInteractiveTransitioning?

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let mainVC = presenting as? MainViewController,
            let tabSwitcherVC = presented as? TabSwitcherViewController else {
            return nil
        }

        let isNTP = mainVC.newTabPageViewController != nil
        Logger.swipeUpToTabSwitcher.debug("animationController(forPresented) interactive=\(self.activeInteractiveTransition != nil, privacy: .public) ntp=\(isNTP, privacy: .public)")

        if isNTP {
            return FromHomeScreenTransition(mainViewController: mainVC,
                                            tabSwitcherViewController: tabSwitcherVC)
        }

        return FromWebViewTransition(mainViewController: mainVC,
                                     tabSwitcherViewController: tabSwitcherVC)
    }

    func interactionControllerForPresentation(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        // nil for button taps → UIKit performs the normal non-interactive present. When a swipe-up
        // gesture is live, the custom controller takes over and `animator.animateTransition` is bypassed
        // (the animator is still used for `transitionDuration` and the non-interactive button tap).
        Logger.swipeUpToTabSwitcher.debug("interactionControllerForPresentation: activeInteractiveTransition != nil = \(self.activeInteractiveTransition != nil, privacy: .public)")
        return activeInteractiveTransition
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let tabSwitcherVC = dismissed as? TabSwitcherViewController else { return nil }
        
        if let tab = tabSwitcherVC.tabsModel.currentTab, tab.link == nil {
            return ToHomeScreenTransition(tabSwitcherViewController: tabSwitcherVC)
        }
        return ToWebViewTransition(tabSwitcherViewController: tabSwitcherVC)
    }
}

extension TabSwitcherTransition {

    func adjustFrame(_ frame: CGRect, forAddressBarPosition position: AddressBarPosition, byMinY minY: CGFloat = 0.0, byHeight height: CGFloat = 0.0) -> CGRect {
        guard position.isBottom else { return frame }
        return CGRect(x: frame.minX,
                           y: frame.minY + minY,
                           width: frame.width,
                           height: frame.height + height)
    }

    /// Builds the card's top bar (favicon + title + X) for the swipe-up drag, populated from `tab`,
    /// matching `TabViewGridCell`'s header so the handoff to the real cell is seamless. Decorative only —
    /// the X is **not** wired to close anything (the card is transient). Shared by both `From*` animators.
    func makeSwipeUpCardHeader(for tab: Tab?) -> SwipeUpCardHeaderView {
        let header = SwipeUpCardHeaderView()
        header.configure(for: tab)
        return header
    }

}

/// The all-tabs grid cell's top bar (favicon + title + close X), replicated at the top of the dragged
/// swipe-up card so it lands without empty space above the preview. Frame-driven (not Auto Layout) so the
/// interaction controller can animate its `frame` alongside the rest of the card; it lays its content out
/// in `layoutSubviews` to mirror `TabViewGridCell`'s header metrics, and at the commit snap it coincides
/// exactly with the real cell's header. The X is purely decorative (the card is removed on commit).
final class SwipeUpCardHeaderView: UIView {

    /// Mirror `TabViewGridCell.Constants` so the favicon/title/X line up with the real cell's header.
    private enum Constants {
        static let headerHeight = TabViewGridCell.Constants.headerHeight          // 44 — content layout box
        static let faviconSize = TabViewGridCell.Constants.faviconSize            // 16
        static let faviconLeadingPadding = TabViewGridCell.Constants.faviconLeadingPadding   // 12
        static let faviconTrailingPadding = TabViewGridCell.Constants.faviconTrailingPadding // 8
        static let removeButtonWidth = TabViewGridCell.Constants.headerHeight     // 44 (square button container)
        /// Matches `TabViewCell` header title→close spacing (negative = title overlaps the button's padding).
        static let titleToButtonSpacing = TabViewCell.Constants.removeButtonTextSpacingRegular // -12
    }

    let favicon = UIImageView()
    let title = FadeOutLabel()
    let removeButton = BrowserChromeButton(.tabSwitcher)

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false // decorative; never intercepts touches

        favicon.contentMode = .scaleAspectFit
        favicon.layer.cornerRadius = TabViewCell.Constants.faviconCornerRadius
        favicon.layer.cornerCurve = .continuous
        favicon.layer.masksToBounds = true
        addSubview(favicon)

        title.font = .daxFootnoteSemibold()
        title.primaryColor = UIColor(designSystemColor: .textPrimary)
        title.lineBreakMode = .byClipping
        title.adjustsFontForContentSizeCategory = true
        addSubview(title)

        removeButton.setImage(DesignSystemImages.Glyphs.Size16.close, for: .normal)
        removeButton.tintColor = UIColor(designSystemColor: .icons)
        removeButton.isUserInteractionEnabled = false
        addSubview(removeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(for tab: Tab?) {
        // Mirror `TabViewCell.update(withTab:)` for the three surfaces we present from (web / NTP / Duck.ai).
        if let tab, tab.isAITab {
            title.text = UserText.omnibarFullAIChatModeDisplayTitle
            favicon.image = UIImage(resource: .duckAIDefault)
        } else if let tab, tab.link == nil {
            // New Tab Page: use its title + the Dax logo, matching the empty-tab cell header.
            title.text = UserText.homeTabTitle
            favicon.image = UIImage(resource: .logo)
        } else if let link = tab?.link {
            title.text = link.displayTitle
            if let url = tab?.link?.url, url.isDuckPlayer {
                favicon.image = UIImage(resource: .duckPlayerURLIcon)
            } else {
                favicon.loadFavicon(forDomain: link.url.host, usingCache: .tabs)
            }
        } else {
            title.text = nil
            favicon.image = DesignSystemImages.Glyphs.Size24.globe
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Lay content out in a `headerHeight`-tall box pinned to the top, matching the grid cell's
        // top-aligned header stack so favicon/title/X sit at the same vertical centre as the real cell.
        let contentHeight = Constants.headerHeight
        favicon.frame = CGRect(x: Constants.faviconLeadingPadding,
                               y: (contentHeight - Constants.faviconSize) / 2,
                               width: Constants.faviconSize,
                               height: Constants.faviconSize)

        let buttonWidth = Constants.removeButtonWidth
        removeButton.frame = CGRect(x: bounds.width - buttonWidth,
                                    y: 0,
                                    width: buttonWidth,
                                    height: contentHeight)

        let titleX = favicon.frame.maxX + Constants.faviconTrailingPadding
        // The title runs up to the close button, minus the (negative) spacing the real cell uses.
        let titleMaxX = removeButton.frame.minX - Constants.titleToButtonSpacing
        title.frame = CGRect(x: titleX,
                             y: 0,
                             width: max(0, titleMaxX - titleX),
                             height: contentHeight)
    }
}
