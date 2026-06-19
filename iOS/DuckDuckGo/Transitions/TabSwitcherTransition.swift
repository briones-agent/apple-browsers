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
    /// Full-content frame of `imageContainer` at progress 0 (where the page sits, minus the omnibar).
    let initialContainerFrame: CGRect
    /// Destination grid-cell frame `imageContainer` snaps to on commit (collection pre-scrolled to it).
    let destinationCellFrame: CGRect
    /// `imageView` frame inside the settled cell (web: `previewFrame`; NTP: centered logo frame).
    let destinationImageViewFrame: CGRect
}

/// Implemented by the `From*` presentation animators so the interactive swipe-up controller can build
/// the dragged preview using their existing setup + cell-frame math instead of duplicating it.
protocol SwipeUpInteractiveTransition: AnyObject {
    /// Configures `solidBackground` + `imageContainer` (+ image / snapshot / logo) — frames, content,
    /// border colour — and pre-scrolls the tab switcher's collection to the current tab, returning the
    /// geometry the interaction controller drives. Does **not** add anything to the view hierarchy: the
    /// controller owns z-ordering (solidBackground at the bottom, then the overview + blur, then the
    /// card on top). Returns nil if the required tab/preview/layout isn't available.
    func prepareInteractivePreview(finalFrame: CGRect) -> SwipeUpInteractivePreview?
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

}
