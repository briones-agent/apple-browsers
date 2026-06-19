//
//  SwipeUpToTabSwitcherInteractiveTransition.swift
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

import UIKit
import Core
import os.log

/// Custom interaction controller for the free-form swipe-up-to-tab-overview gesture.
///
/// Unlike `UIPercentDrivenInteractiveTransition` (which only scrubs a predetermined keyframe path), this
/// controller is driven *manually* so the dragged page preview can follow the finger in 2D and scale
/// down with vertical progress, then snap to its destination grid cell on commit. The presented tab
/// switcher stays a real `present(...)`ed VC; this just replaces the percent-driven interactor.
///
/// Frame geometry (initial full-content frame, destination cell frame, settled image frame) is produced
/// by the `From*` animator's `prepareInteractivePreview(...)`, so the snap lands pixel-identical to the
/// non-interactive button-tap transition. The overview behind the card blurs more the further up you
/// drag and sharpens on release.
final class SwipeUpToTabSwitcherInteractiveTransition: NSObject, UIViewControllerInteractiveTransitioning {

    enum Constants {
        /// Smallest scale the dragged card shrinks to at full vertical progress. Tunable for feel.
        static let minScale: CGFloat = 0.5
        /// Base snap duration on release.
        static let snapDuration: TimeInterval = 0.35
        /// Floor/ceiling for the velocity-scaled commit duration after a flick.
        static let minCommitDuration: TimeInterval = 0.18
        static let maxCommitDuration: TimeInterval = 0.40
        /// Spring damping for the *cancel* (return-to-page) snap — high, so it settles calmly without a
        /// bounce (a bounce on the way back to the page feels wrong).
        static let springDamping: CGFloat = 0.86
        /// Spring damping for the *commit* snap into the destination cell — lower than `springDamping`
        /// to give a tasteful little settle/bounce as the card lands. Tunable for feel.
        static let commitSpringDamping: CGFloat = 0.74
        /// Multiplier turning the flick's vertical speed into the commit spring's initial velocity, so a
        /// harder flick lands with a touch more energy. Capped by `maxCommitInitialSpringVelocity`.
        static let commitInitialSpringVelocityFactor: CGFloat = 0.0009
        static let maxCommitInitialSpringVelocity: CGFloat = 3.0

        // MARK: Blur (inverted: heaviest at the bottom, eases as the finger rises; only commit clears it)

        /// Blur fraction (0...1 of the property animator) at the very start of the drag — the heaviest
        /// the overview gets. 1.0 = the full `.systemThinMaterial`.
        static let maxBlur: CGFloat = 1.0
        /// Floor the blur eases down to at the top of the drag: it never fully clears mid-drag (only the
        /// commit sharpens to 0), so you always retain a little frosting over the overview.
        static let minBlurDuringDrag: CGFloat = 0.18
        /// Smoothstep window (in *blur progress*, 0 = bottom, 1 = top) over which the blur eases from
        /// `maxBlur` down to `minBlurDuringDrag`. Below `blurEaseStart` it stays heavy (grid not really
        /// visible); past `blurEaseEnd` it has reached the floor. Centring the window past the midpoint
        /// keeps it "still very blurry" around halfway while clearing meaningfully up high.
        static let blurEaseStart: CGFloat = 0.30
        static let blurEaseEnd: CGFloat = 0.85
        /// Fraction of the full content/screen height the finger must travel for blur progress to reach
        /// 1. Bigger than the visual (card-shrink) reference so the blur keeps easing across the UPPER
        /// half of the screen rather than saturating at mid-screen.
        static let blurProgressReferenceFraction: CGFloat = 0.9
    }

    private var transitionContext: UIViewControllerContextTransitioning?
    /// The `From*` animator that built the preview; bypassed for `animateTransition`, used only for setup.
    private var animator: (UIViewControllerAnimatedTransitioning & SwipeUpInteractiveTransition)?
    private var preview: SwipeUpInteractivePreview?
    private weak var toView: UIView?

    private var blurView: UIVisualEffectView?
    private var blurAnimator: UIViewPropertyAnimator?

    /// Latest finger translation and applied scale, so the commit/cancel snap can compute the card's
    /// exact current visual rect (bottom-centre anchor) and animate `frame` from there without a flicker.
    private var lastTranslation: CGPoint = .zero
    private var lastScale: CGFloat = 1

    // MARK: UIViewControllerInteractiveTransitioning

    func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        Logger.swipeUpToTabSwitcher.debug("interactive.start")
        self.transitionContext = transitionContext

        let container = transitionContext.containerView

        guard let toVC = transitionContext.viewController(forKey: .to) as? TabSwitcherViewController,
              let fromVC = transitionContext.viewController(forKey: .from) as? MainViewController else {
            Logger.swipeUpToTabSwitcher.debug("interactive.start: missing to/from VC — completing immediately")
            finishImmediatelyAsCancel()
            return
        }

        let finalFrame = transitionContext.finalFrame(for: toVC)
        toVC.view.frame = finalFrame
        toVC.view.alpha = 0
        toVC.prepareForPresentation()
        toView = toVC.view

        // Blur layer over the overview, scrubbed via `fractionComplete`. Inverted Safari-style feel:
        // heaviest at the bottom (`maxBlur`) and easing as the finger rises, so you see more of the
        // overview the higher you go; only commit sharpens it fully. `.systemThinMaterial` reads well over
        // the overview's light-gray background; revisit on-device (try `.regular`/`.systemMaterial`).
        let blurView = UIVisualEffectView(effect: nil)
        blurView.frame = finalFrame
        self.blurView = blurView

        let blurAnimator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            blurView.effect = UIBlurEffect(style: .systemThinMaterial)
        }
        blurAnimator.pausesOnCompletion = true
        blurAnimator.fractionComplete = Constants.maxBlur // heaviest at the start of the drag
        self.blurAnimator = blurAnimator

        // Build the dragged card via the From* animator's shared setup (web or NTP picked by surface).
        let animator: (UIViewControllerAnimatedTransitioning & SwipeUpInteractiveTransition)
        if fromVC.newTabPageViewController != nil {
            animator = FromHomeScreenTransition(mainViewController: fromVC, tabSwitcherViewController: toVC)
        } else {
            animator = FromWebViewTransition(mainViewController: fromVC, tabSwitcherViewController: toVC)
        }
        self.animator = animator

        guard let preview = animator.prepareInteractivePreview(finalFrame: finalFrame) else {
            // No preview/tab/layout — fall back to a plain sharpen-in so we never get stuck mid-transition.
            Logger.swipeUpToTabSwitcher.debug("interactive.start: prepareInteractivePreview returned nil — fading switcher in")
            container.addSubview(toVC.view)
            UIView.animate(withDuration: TabSwitcherTransition.Constants.duration) {
                toVC.view.alpha = 1
            } completion: { _ in
                transitionContext.completeTransition(true)
            }
            return
        }
        self.preview = preview

        // Z-order, bottom → top: solidBackground (hides the from-VC) under the overview + blur under the
        // dragged card. The presenting VC's real content sits below the (transparent) container.
        container.addSubview(preview.solidBackground)
        container.addSubview(toVC.view)
        container.addSubview(blurView)
        container.addSubview(preview.imageContainer)

        // The card is positioned by `initialContainerFrame` and the drag only mutates `transform`
        // (mutating `frame` while transformed is undefined in UIKit). The transform scales the card about
        // its own BOTTOM-CENTRE and translates by the finger, so the bottom edge stays put as the card
        // shrinks and rides the finger — like lifting the page by its bottom edge (the swipe starts on
        // the bottom bar), instead of the card drifting up off the finger. The commit/cancel snap
        // reconstructs the card's exact current rect from `lastTranslation`/`lastScale` (same bottom-centre
        // anchoring) and animates `frame` from there, so there is no flicker when the transform is cleared.
        preview.imageContainer.frame = preview.initialContainerFrame
        preview.imageContainer.transform = .identity
        preview.homeScreenSnapshot?.alpha = 1
        lastTranslation = .zero
        lastScale = 1
        Logger.swipeUpToTabSwitcher.debug("interactive.start: ready initial=\(String(describing: preview.initialContainerFrame), privacy: .public) cell=\(String(describing: preview.destinationCellFrame), privacy: .public)")
    }

    // MARK: Driving the drag

    /// Called from the gesture's `.changed`. Moves the card under the finger (`translation`), shrinks it
    /// with `verticalProgress`, ramps the corner/border, and scrubs the overview blur (inverted: heaviest
    /// at the bottom, eases up as the finger rises).
    func update(translation: CGPoint, verticalProgress: CGFloat) {
        guard let preview, let transitionContext else { return }
        let progress = min(max(verticalProgress, 0), 1)

        // Scale 1.0 → minScale as the drag rises, anchored about the card's BOTTOM-CENTRE, then translated
        // by the finger: T(translation) · T(0, +h/2) · S(scale) · T(0, -h/2). The bottom edge stays at
        // `initialContainerFrame.maxY` while the top comes down, and tracks the finger in x and y. At
        // (translation == .zero, scale == 1) this collapses to identity, so there is no start jump.
        let scale = 1.0 - (1.0 - Constants.minScale) * progress
        lastTranslation = translation
        lastScale = scale
        let halfHeight = preview.initialContainerFrame.height / 2
        preview.imageContainer.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .translatedBy(x: 0, y: halfHeight)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: 0, y: -halfHeight)

        // Corner + border ramp in lockstep with progress (preserves the existing settled-cell look).
        preview.imageContainer.layer.cornerRadius = TabViewCell.Constants.cellCornerRadius * progress
        preview.imageContainer.layer.borderWidth = TabViewCell.Constants.selectedBorderWidth * progress

        // NTP cross-fade: snapshot carries the start, the crisp centred logo carries the top of the drag
        // (also dodges the Dax-logo squeeze). No-op for web (homeScreenSnapshot == nil, imageView.alpha
        // already 1 from setup defaults).
        if preview.homeScreenSnapshot != nil {
            preview.homeScreenSnapshot?.alpha = max(0, 1 - progress / 0.3)
            preview.imageView.alpha = min(1, max(0, (progress - 0.2) / 0.3))
        }

        // Inverted blur: heaviest at the bottom, easing toward `minBlurDuringDrag` as the finger rises so
        // you see more of the overview the higher you go (where you care about where you'll land). Driven
        // off a separate, near-full-height blur progress (not the card-shrink `verticalProgress`, which
        // saturates at mid-screen) so it keeps clearing across the upper half.
        let blur = currentBlurFraction()
        blurAnimator?.fractionComplete = blur
        transitionContext.updateInteractiveTransition(progress)

        Logger.swipeUpToTabSwitcher.debug("interactive.update progress=\(Double(progress), privacy: .public) tx=\(Double(translation.x), privacy: .public) ty=\(Double(translation.y), privacy: .public) scale=\(Double(scale), privacy: .public) blur=\(Double(blur), privacy: .public)")
    }

    /// Blur fraction for the current drag, inverted and eased: `maxBlur` at the bottom, smoothstepped down
    /// to `minBlurDuringDrag` between `blurEaseStart` and `blurEaseEnd` of the (near-full-height) blur
    /// progress. Stays at least `minBlurDuringDrag` for the whole drag — only commit sharpens to 0.
    private func currentBlurFraction() -> CGFloat {
        guard let preview else { return Constants.maxBlur }
        // Full-screen reference (overview height) scaled by `blurProgressReferenceFraction`, so the blur
        // keeps easing across the upper half rather than saturating at mid-screen like the card shrink.
        let fullHeight = max(blurView?.frame.height ?? preview.initialContainerFrame.height, 1)
        let reference = max(fullHeight * Constants.blurProgressReferenceFraction, 1)
        let blurProgress = min(max(-lastTranslation.y / reference, 0), 1)
        // Smoothstep 0→1 across the ease window, then map onto maxBlur→minBlurDuringDrag (inverted).
        let eased = smoothstep(Constants.blurEaseStart, Constants.blurEaseEnd, blurProgress)
        return Constants.maxBlur - (Constants.maxBlur - Constants.minBlurDuringDrag) * eased
    }

    /// Standard Hermite smoothstep: 0 below `edge0`, 1 above `edge1`, eased S-curve in between.
    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return x <= edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Commit / cancel

    /// Commit: snap the card from wherever the finger left it to its destination cell, sharpen the
    /// overview, fade the switcher fully in, then tear down. `verticalVelocity` (pt/s, negative = up)
    /// shortens the snap after a flick.
    func finish(verticalVelocity: CGFloat = 0) {
        guard let preview, let transitionContext, let toView else {
            finishImmediatelyAsCancel()
            return
        }
        let duration = commitDuration(verticalVelocity: verticalVelocity)
        Logger.swipeUpToTabSwitcher.debug("interactive.finish duration=\(Double(duration), privacy: .public) v=\(Double(verticalVelocity), privacy: .public)")

        // Bake the live transform into the card's frame (flicker-free) so we can animate `frame` to the
        // cell — the cell has a different aspect ratio than the page, which a single transform can't match.
        bakeCurrentTransformIntoFrame(preview)

        // Lower damping than the cancel path so the card settles into the cell with a tasteful little
        // bounce, plus a small initial velocity carried over from the flick (capped) so a harder flick
        // lands with a touch more energy.
        let initialSpringVelocity = min(abs(verticalVelocity) * Constants.commitInitialSpringVelocityFactor,
                                        Constants.maxCommitInitialSpringVelocity)
        UIView.animate(withDuration: duration,
                       delay: 0,
                       usingSpringWithDamping: Constants.commitSpringDamping,
                       initialSpringVelocity: initialSpringVelocity,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            preview.imageContainer.frame = preview.destinationCellFrame
            preview.imageContainer.layer.cornerRadius = TabViewCell.Constants.cellCornerRadius
            preview.imageContainer.layer.borderWidth = TabViewCell.Constants.selectedBorderWidth
            preview.imageView.frame = preview.destinationImageViewFrame
            preview.imageView.alpha = 1
            preview.homeScreenSnapshot?.frame = CGRect(origin: .zero, size: preview.destinationCellFrame.size)
            preview.homeScreenSnapshot?.alpha = 0
            toView.alpha = 1
            self.blurAnimator?.fractionComplete = 0 // sharpen: land in a crisp overview
        } completion: { _ in
            self.tearDown()
            transitionContext.finishInteractiveTransition()
            transitionContext.completeTransition(true)
        }
    }

    /// Cancel: animate the card back to full screen, clear corner/border/blur, hide the switcher, tear down.
    func cancel() {
        guard let preview, let transitionContext, let toView else {
            finishImmediatelyAsCancel()
            return
        }
        Logger.swipeUpToTabSwitcher.debug("interactive.cancel")

        bakeCurrentTransformIntoFrame(preview)

        UIView.animate(withDuration: Constants.snapDuration,
                       delay: 0,
                       usingSpringWithDamping: Constants.springDamping,
                       initialSpringVelocity: 0,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            preview.imageContainer.frame = preview.initialContainerFrame
            preview.imageContainer.layer.cornerRadius = 0
            preview.imageContainer.layer.borderWidth = 0
            preview.imageView.frame = CGRect(origin: .zero, size: preview.initialContainerFrame.size)
            preview.homeScreenSnapshot?.frame = CGRect(origin: .zero, size: preview.initialContainerFrame.size)
            preview.homeScreenSnapshot?.alpha = 1
            preview.imageView.alpha = preview.homeScreenSnapshot != nil ? 0 : 1
            toView.alpha = 0
            self.blurAnimator?.fractionComplete = 0
        } completion: { _ in
            self.tearDown()
            transitionContext.cancelInteractiveTransition()
            transitionContext.completeTransition(false)
        }
    }

    // MARK: Helpers

    private func commitDuration(verticalVelocity: CGFloat) -> TimeInterval {
        guard verticalVelocity < -SwipeUpToTabSwitcher.flickVelocity else { return Constants.snapDuration }
        // Faster the harder the flick, clamped to a comfortable band.
        let speedup = min(1, (abs(verticalVelocity) - SwipeUpToTabSwitcher.flickVelocity) / 2000)
        return Constants.maxCommitDuration - (Constants.maxCommitDuration - Constants.minCommitDuration) * speedup
    }

    /// Reconstructs the card's exact on-screen rect from the last drag transform (bottom-centre-anchor
    /// scale + finger translate over `initialContainerFrame`), clears the transform and sets `frame` to
    /// that rect, and re-pins the image/snapshot to fill the baked card. Visually a no-op (no flicker),
    /// but it lets the commit/cancel animation drive `frame` to a target with a different aspect ratio.
    private func bakeCurrentTransformIntoFrame(_ preview: SwipeUpInteractivePreview) {
        let initial = preview.initialContainerFrame
        let size = CGSize(width: initial.width * lastScale, height: initial.height * lastScale)
        // Bottom-centre rides the finger: it sits at the card's original bottom-centre plus the finger's
        // translation. The shrink pulls the top edge down toward it (origin.y = bottomCentre.y - height).
        let bottomCenter = CGPoint(x: initial.midX + lastTranslation.x, y: initial.maxY + lastTranslation.y)
        let visualRect = CGRect(x: bottomCenter.x - size.width / 2,
                                y: bottomCenter.y - size.height,
                                width: size.width,
                                height: size.height)
        preview.imageContainer.transform = .identity
        preview.imageContainer.frame = visualRect
        let bounds = CGRect(origin: .zero, size: visualRect.size)
        preview.imageView.frame = bounds
        preview.homeScreenSnapshot?.frame = bounds
    }

    private func tearDown() {
        preview?.solidBackground.removeFromSuperview()
        preview?.imageContainer.removeFromSuperview()
        blurView?.removeFromSuperview()
        blurAnimator?.stopAnimation(true) // avoid a leaked running property animator
        blurAnimator = nil
        blurView = nil
        preview = nil
        animator = nil
    }

    /// Last-resort teardown when we can't drive a real animation (missing context/preview).
    private func finishImmediatelyAsCancel() {
        let context = transitionContext
        tearDown()
        context?.cancelInteractiveTransition()
        context?.completeTransition(false)
    }
}
