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
        let referenceDistance = max(viewCoordinator.contentContainer.bounds.height, 1)
        let progress = SwipeUpToTabSwitcher.progress(translationY: translation.y,
                                                     referenceDistance: referenceDistance)

        switch gesture.state {
        case .began:
            Logger.swipeUpToTabSwitcher.debug("pan .began translation.y=\(Double(translation.y), privacy: .public) ref=\(Double(referenceDistance), privacy: .public)")
            // Ensure the web-view transition has a snapshot to animate even on a never-previewed tab.
            captureCurrentTabPreviewForInteractiveTransitionIfNeeded()

            let interactor = UIPercentDrivenInteractiveTransition()
            interactor.completionCurve = .easeOut
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
            Logger.swipeUpToTabSwitcher.debug("pan .changed progress=\(Double(progress), privacy: .public) hasInteractor=\(self.tabSwitcherInteractor != nil, privacy: .public)")
            tabSwitcherInteractor?.update(progress)

        case .ended:
            guard let interactor = tabSwitcherInteractor else {
                Logger.swipeUpToTabSwitcher.debug("pan .ended but no interactor")
                return
            }
            let velocity = gesture.velocity(in: gesture.view)
            let commit = SwipeUpToTabSwitcher.shouldCommit(progress: progress, verticalVelocity: velocity.y)
            Logger.swipeUpToTabSwitcher.debug("pan .ended progress=\(Double(progress), privacy: .public) v.y=\(Double(velocity.y), privacy: .public) commit=\(commit, privacy: .public)")
            if commit {
                // Finish a touch faster after a flick so the tail feels responsive.
                interactor.completionSpeed = velocity.y < -SwipeUpToTabSwitcher.flickVelocity ? 1.2 : 1.0
                fireTabSwitcherOpenedPixels()
                interactor.finish()
            } else {
                interactor.cancel()
            }
            // `tabSwitcherInteractor` is released by the presentation's transition-coordinator completion.

        case .cancelled, .failed:
            Logger.swipeUpToTabSwitcher.debug("pan .cancelled/.failed")
            tabSwitcherInteractor?.cancel()

        default:
            break
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
