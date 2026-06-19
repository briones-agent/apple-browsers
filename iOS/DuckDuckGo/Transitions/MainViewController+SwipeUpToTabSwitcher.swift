//
//  MainViewController+SwipeUpToTabSwitcher.swift
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

/// Distinct subclass so `MainViewController`'s gesture-recognizer delegate can identify this gesture
/// and disambiguate it from the horizontal tab-swipe pan that shares the bottom bar.
final class SwipeUpToTabSwitcherPanGestureRecognizer: UIPanGestureRecognizer {

    // TEMP debug: confirm whether this recognizer receives touches at all. When the swipe starts on
    // the address bar, the omnibar's collection view / text field may swallow the touch before it
    // reaches a recognizer attached to the container.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Logger.swipeUpToTabSwitcher.debug("recognizer.touchesBegan view=\(String(describing: type(of: self.view)), privacy: .public)")
        super.touchesBegan(touches, with: event)
    }
}

/// Pure, testable parameters and decisions for the interactive swipe-up-to-tab-overview gesture.
enum SwipeUpToTabSwitcher {

    /// Progress (0...1) past which lifting the finger commits to the overview.
    static let commitProgress: CGFloat = 0.3
    /// Upward velocity (points/second magnitude) that commits as a "flick" regardless of progress.
    static let flickVelocity: CGFloat = 800

    /// Progress past which the bottom bar fades out. Above `showBarsBelowProgress` so the pair forms a
    /// hysteresis band that stops the bars flickering when the finger lingers around the threshold.
    static let hideBarsAboveProgress: CGFloat = 0.05
    /// Progress below which a faded-out bottom bar fades back in.
    static let showBarsBelowProgress: CGFloat = 0.03
    /// Duration of the bottom-bar fade in/out during the drag.
    static let barFadeDuration: TimeInterval = 0.2

    /// Fraction of the content height that maps to full *visual* progress (card fully shrunk + overview
    /// fully blurred). The product owner thinks of ~100% ≈ finger near mid-screen, so the card reaches
    /// its minimum size / max blur around half the content height rather than the full height. This is
    /// independent of `commitProgress` (which still uses the full-height reference below) — visuals
    /// saturate well before the commit threshold needs to be hit. Tune for feel on-device.
    static let visualProgressReferenceFraction: CGFloat = 0.5

    /// Maps an upward drag (negative `translationY`) to 0...1 transition progress.
    static func progress(translationY: CGFloat, referenceDistance: CGFloat) -> CGFloat {
        guard referenceDistance > 0 else { return 0 }
        return min(max(-translationY / referenceDistance, 0), 1)
    }

    /// Commit on a quick upward flick, or when dragged past `commitProgress`.
    /// `verticalVelocity` is the pan's y-velocity (negative = upward).
    static func shouldCommit(progress: CGFloat, verticalVelocity: CGFloat) -> Bool {
        if verticalVelocity < -flickVelocity {
            return true
        }
        return progress >= commitProgress
    }
}

extension MainViewController {

    /// Installs the interactive swipe-up gesture on the bottom-bar region (toolbar + address-bar
    /// container). No-op unless the feature flag is on; per-event gating (iPhone, bottom address bar,
    /// not editing…) lives in `shouldBeginSwipeUpToTabSwitcherPan`.
    func installSwipeUpToTabSwitcherGesture() {
        let flagOn = featureFlagger.isFeatureOn(.swipeUpToTabSwitcher)
        Logger.swipeUpToTabSwitcher.debug("install: flagOn=\(flagOn, privacy: .public)")
        guard flagOn else { return }
        viewCoordinator.toolbar.addGestureRecognizer(makeSwipeUpToTabSwitcherPanGesture())
        viewCoordinator.navigationBarContainer.addGestureRecognizer(makeSwipeUpToTabSwitcherPanGesture())
        Logger.swipeUpToTabSwitcher.debug("install: added pan to toolbar + navigationBarContainer")
    }

    private func makeSwipeUpToTabSwitcherPanGesture() -> SwipeUpToTabSwitcherPanGestureRecognizer {
        let pan = SwipeUpToTabSwitcherPanGestureRecognizer(target: self,
                                                           action: #selector(handleSwipeUpToTabSwitcherPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func shouldBeginSwipeUpToTabSwitcherPan(_ pan: UIPanGestureRecognizer) -> Bool {
        let flagOn = featureFlagger.isFeatureOn(.swipeUpToTabSwitcher)
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isBottom = appSettings.currentAddressBarPosition.isBottom
        let noSwitcher = tabSwitcherController == nil
        let noModal = presentedViewController == nil
        let notEditing = !omniBar.isTextFieldEditing
        let velocity = pan.velocity(in: pan.view)
        // Only claim a dominantly-upward drag, so the horizontal tab-swipe pan keeps left/right gestures.
        let upwardDominant = velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
        let result = flagOn && isPhone && isBottom && noSwitcher && noModal && notEditing && upwardDominant

        let msg = "shouldBegin result=\(result) flagOn=\(flagOn) isPhone=\(isPhone) isBottom=\(isBottom) "
            + "noSwitcher=\(noSwitcher) noModal=\(noModal) notEditing=\(notEditing) upwardDominant=\(upwardDominant) "
            + "v=(\(velocity.x), \(velocity.y)) view=\(type(of: pan.view))"
        Logger.swipeUpToTabSwitcher.debug("\(msg, privacy: .public)")

        return result
    }

    @objc func handleSwipeUpToTabSwitcherPan(_ gesture: SwipeUpToTabSwitcherPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        // Full-height reference drives the *commit* threshold + bar-fade hysteresis (unchanged trigger).
        let referenceDistance = max(viewCoordinator.contentContainer.bounds.height, 1)
        let progress = SwipeUpToTabSwitcher.progress(translationY: translation.y,
                                                     referenceDistance: referenceDistance)
        // Half-height reference drives the *visual* progress (card shrink + overview blur): the card
        // reaches its minimum size / max blur around mid-screen.
        let visualReference = max(referenceDistance * SwipeUpToTabSwitcher.visualProgressReferenceFraction, 1)
        let visualProgress = SwipeUpToTabSwitcher.progress(translationY: translation.y,
                                                           referenceDistance: visualReference)

        switch gesture.state {
        case .began:
            Logger.swipeUpToTabSwitcher.debug("pan .began translation.y=\(Double(translation.y), privacy: .public) ref=\(Double(referenceDistance), privacy: .public)")
            // Ensure the web-view transition has a snapshot to animate even on a never-previewed tab.
            captureCurrentTabPreviewForInteractiveTransitionIfNeeded()

            let interactor = SwipeUpToTabSwitcherInteractiveTransition()
            tabSwitcherInteractor = interactor

            // Mirror the button-tap path's dismissal of any transient omnibar/suggestion state.
            performCancel()

            let started = beginInteractiveTabSwitcherPresentation(interactor: interactor)
            Logger.swipeUpToTabSwitcher.debug("pan .began -> beginInteractive started=\(started, privacy: .public)")
            if !started {
                // Presentation didn't start, so no transition coordinator will clear the interactor.
                tabSwitcherInteractor = nil
            }

        case .changed:
            Logger.swipeUpToTabSwitcher.debug("pan .changed progress=\(Double(progress), privacy: .public) visual=\(Double(visualProgress), privacy: .public) hasInteractor=\(self.tabSwitcherInteractor != nil, privacy: .public)")
            // Only drive the transition + bar fade while a controller is live. If the present failed at
            // `.began` (interactor nil), doing nothing here keeps the bottom bar from being faded out
            // with no settled transition to restore it.
            guard let interactor = tabSwitcherInteractor else { return }
            // Card follows the finger in 2D (full translation) and shrinks/blurs with visual progress.
            interactor.update(translation: translation, verticalProgress: visualProgress)
            updateBottomBarVisibilityForSwipeUp(progress: progress)

        case .ended:
            guard let interactor = tabSwitcherInteractor else {
                Logger.swipeUpToTabSwitcher.debug("pan .ended but no interactor")
                return
            }
            let velocity = gesture.velocity(in: gesture.view)
            // Commit decision unchanged: vertical drag past threshold OR upward flick (independent of
            // horizontal position).
            let commit = SwipeUpToTabSwitcher.shouldCommit(progress: progress, verticalVelocity: velocity.y)
            Logger.swipeUpToTabSwitcher.debug("pan .ended progress=\(Double(progress), privacy: .public) v.y=\(Double(velocity.y), privacy: .public) commit=\(commit, privacy: .public)")
            if commit {
                fireTabSwitcherOpenedPixels()
                // Leave the bars hidden through the finish — the switcher takes over the screen. They
                // are restored (and the flag reset) by the presentation's transition-coordinator
                // completion in `beginInteractiveTabSwitcherPresentation`. The card snaps to its cell;
                // a faster snap after a flick is handled inside the controller via `verticalVelocity`.
                interactor.finish(verticalVelocity: velocity.y)
            } else {
                // Snapping back to the page: fade the chrome back in so it returns with the content.
                showBottomBarForSwipeUp()
                interactor.cancel()
            }
            // `tabSwitcherInteractor` is released by the presentation's transition-coordinator completion.

        case .cancelled, .failed:
            Logger.swipeUpToTabSwitcher.debug("pan .cancelled/.failed")
            showBottomBarForSwipeUp()
            tabSwitcherInteractor?.cancel()

        default:
            break
        }
    }

    /// Fades the whole bottom bar (address-bar container + toolbar) in/out as the drag crosses the
    /// hysteresis thresholds, so the chrome gets out of the way while the page lifts toward the
    /// overview. Each fade fires only once per crossing, tracked by `isBottomBarHiddenForSwipeUp`.
    private func updateBottomBarVisibilityForSwipeUp(progress: CGFloat) {
        if !isBottomBarHiddenForSwipeUp, progress > SwipeUpToTabSwitcher.hideBarsAboveProgress {
            hideBottomBarForSwipeUp()
        } else if isBottomBarHiddenForSwipeUp, progress < SwipeUpToTabSwitcher.showBarsBelowProgress {
            showBottomBarForSwipeUp()
        }
    }

    private func hideBottomBarForSwipeUp() {
        guard !isBottomBarHiddenForSwipeUp else { return }
        isBottomBarHiddenForSwipeUp = true
        Logger.swipeUpToTabSwitcher.debug("bottom bar fade out")
        // IMPORTANT: fade `alpha`, never set `isHidden`. Alpha 0 only affects hit-testing for the START
        // of new touches, so the in-flight pan keeps tracking; `isHidden` would drop it mid-gesture.
        UIView.animate(withDuration: SwipeUpToTabSwitcher.barFadeDuration) {
            self.viewCoordinator.navigationBarContainer.alpha = 0
            self.viewCoordinator.toolbar.alpha = 0
        }
    }

    /// Fades the bottom bar back to fully visible. Safe to call when already shown (no-op).
    private func showBottomBarForSwipeUp() {
        guard isBottomBarHiddenForSwipeUp else { return }
        isBottomBarHiddenForSwipeUp = false
        Logger.swipeUpToTabSwitcher.debug("bottom bar fade in")
        UIView.animate(withDuration: SwipeUpToTabSwitcher.barFadeDuration) {
            self.viewCoordinator.navigationBarContainer.alpha = 1
            self.viewCoordinator.toolbar.alpha = 1
        }
    }

    /// Synchronously captures the current web tab's content as its preview when none is cached, so the
    /// interactive `FromWebViewTransition` always has an image to scale. No-op for the New Tab Page
    /// (its transition takes a live snapshot) and when a preview already exists.
    private func captureCurrentTabPreviewForInteractiveTransitionIfNeeded() {
        guard newTabPageViewController == nil,
              let tab = tabManager.currentTabsModel.currentTab,
              previewsSource.preview(for: tab) == nil,
              let image = viewCoordinator.contentContainer.createImageSnapshot() else {
            return
        }
        previewsSource.update(preview: image, forTab: tab)
    }
}
