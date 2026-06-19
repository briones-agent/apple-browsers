//
//  HomeScreenTransition.swift
//  DuckDuckGo
//
//  Copyright © 2020 DuckDuckGo. All rights reserved.
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

import Core

protocol HomeScreenTransitionSource: AnyObject {
    var snapshotView: UIView { get }
    var rootContainerView: UIView { get }
}

class HomeScreenTransition: TabSwitcherTransition {
    
    fileprivate var homeScreenSnapshot: UIView?
    fileprivate var settingsButtonSnapshot: UIView?
    
    fileprivate let tabSwitcherSettings: TabSwitcherSettings = DefaultTabSwitcherSettings()
    
    fileprivate func prepareSnapshots(with transitionSource: HomeScreenTransitionSource,
                                      addressBarPosition: AddressBarPosition,
                                      addressBarHeight: CGFloat) {

        let viewToSnapshot = transitionSource.snapshotView
        let sourceBounds = adjustFrame(transitionSource.rootContainerView.bounds, forAddressBarPosition: addressBarPosition, byHeight: -addressBarHeight)
        let frameToSnapshot = transitionSource.rootContainerView.convert(sourceBounds, to: viewToSnapshot)

        if let snapshot = viewToSnapshot.resizableSnapshotView(from: frameToSnapshot,
                                                               afterScreenUpdates: false,
                                                               withCapInsets: .zero) {
            imageContainer.addSubview(snapshot)
            snapshot.frame = imageContainer.bounds
            homeScreenSnapshot = snapshot
        }
    }

    fileprivate func tabSwitcherCellFrame(for attributes: UICollectionViewLayoutAttributes) -> CGRect {
        var targetFrame = self.tabSwitcherViewController.collectionView.convert(attributes.frame,
                                                                                to: self.tabSwitcherViewController.view)
        
        guard tabSwitcherSettings.isGridViewEnabled else {
            return targetFrame
        }
        
        targetFrame.origin.y += TabViewCell.Constants.cellHeaderHeight
        targetFrame.size.height -= TabViewCell.Constants.cellHeaderHeight
        return targetFrame
    }
    
    fileprivate func previewFrame(for cellBounds: CGSize) -> CGRect {
        return CGRect(origin: .zero, size: cellBounds)
            .offsetBy(dx: 0, dy: -TabViewCell.Constants.previewPadding)
    }
    
}

class FromHomeScreenTransition: HomeScreenTransition {
    
    private let mainViewController: MainViewController
    
    init(mainViewController: MainViewController,
         tabSwitcherViewController: TabSwitcherViewController) {
        self.mainViewController = mainViewController

        super.init(tabSwitcherViewController: tabSwitcherViewController)
    }

    override func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        prepareSubviews(using: transitionContext)
        tabSwitcherViewController.view.alpha = 0
        transitionContext.containerView.insertSubview(tabSwitcherViewController.view, belowSubview: imageContainer)
        tabSwitcherViewController.view.frame = transitionContext.finalFrame(for: tabSwitcherViewController)
        tabSwitcherViewController.prepareForPresentation()
        
        guard let homeScreen = mainViewController.newTabPageViewController,
              let tab = mainViewController.tabManager.currentTabsModel.currentTab,
              let rowIndex = tabSwitcherViewController.tabsModel.indexOf(tab: tab),
              let layoutAttr = tabSwitcherViewController.collectionView.layoutAttributesForItem(at: IndexPath(row: rowIndex, section: 0))
        else {
            tabSwitcherViewController.view.alpha = 1
            transitionContext.completeTransition(true)
            return
        }

        let theme = ThemeManager.shared.currentTheme
        
        solidBackground.frame = adjustFrame(homeScreen.view.convert(homeScreen.rootContainerView.frame, to: nil),
                                            forAddressBarPosition: mainViewController.appSettings.currentAddressBarPosition,
                                            byHeight: -mainViewController.omniBar.barView.expectedHeight)
        solidBackground.backgroundColor = theme.backgroundColor

        imageContainer.frame = solidBackground.frame
        imageContainer.backgroundColor = theme.backgroundColor
        
        prepareSnapshots(with: homeScreen, addressBarPosition: mainViewController.appSettings.currentAddressBarPosition, addressBarHeight: mainViewController.omniBar.barView.expectedHeight)

        // The home-screen snapshot is resized from the full-screen aspect ratio down to the cell's
        // aspect ratio. A plain resize stretches its contents (the circular Dax logo) vertically. On
        // the 0.2s button tap that is imperceptible, but the slow interactive swipe makes it obvious.
        // Aspect-fill keeps the snapshot's contents proportional (cropping instead of squeezing) while
        // the container morphs; `imageContainer` already clips, and the crisp `.center` logo below
        // cross-fades in to define the settled state.
        homeScreenSnapshot?.contentMode = .scaleAspectFill
        homeScreenSnapshot?.clipsToBounds = true

        imageView.alpha = 0
        imageView.frame = imageContainer.bounds
        imageView.contentMode = .center
        if tabSwitcherSettings.isGridViewEnabled {
            imageView.image = TabViewCell.logoImage(for: tab)
        }

        // Ramp a border in lockstep with the corner radius (see keyframe below) so a white NTP
        // doesn't blend into the light-gray overview. Matches the all-tabs current-tab cell border
        // (`updateCurrentTabBorder` uses `.decorationTertiary` for the current tab).
        imageContainer.layer.borderWidth = 0
        imageContainer.layer.borderColor = UIColor(designSystemColor: .decorationTertiary).cgColor

        UIView.animateKeyframes(withDuration: TabSwitcherTransition.Constants.duration, delay: 0, options: .calculationModeLinear, animations: {

            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1.0) {
                let containerFrame = self.tabSwitcherCellFrame(for: layoutAttr)
                self.imageContainer.frame = containerFrame
                self.imageContainer.layer.cornerRadius = TabViewCell.Constants.cellCornerRadius
                self.imageContainer.layer.borderWidth = TabViewCell.Constants.selectedBorderWidth
                self.imageContainer.backgroundColor = UIColor(designSystemColor: .surfaceTertiary)
                self.imageView.frame = self.previewFrame(for: self.imageContainer.bounds.size)
                self.homeScreenSnapshot?.frame = self.imageContainer.bounds
            }

            // Fade the (aspect-filled, hence cropping) snapshot out early so the crisp `.center` logo
            // carries most of the drag. This hides the brief snapshot crop and keeps the logo circular
            // throughout; the end state (snapshot gone, logo settled) is unchanged from the button tap.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                self.homeScreenSnapshot?.alpha = 0
            }

            UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) {
                self.tabSwitcherViewController.view.alpha = 1
            }

            if self.tabSwitcherSettings.isGridViewEnabled {
                UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.3) {
                    self.imageView.alpha = 1
                    self.settingsButtonSnapshot?.alpha = 0
                }
            } else {
                UIView.addKeyframe(withRelativeStartTime: 0.7, relativeDuration: 0.3) {
                    self.imageContainer.alpha = 0
                    self.settingsButtonSnapshot?.alpha = 0
                }
            }

        }, completion: { _ in
            self.solidBackground.removeFromSuperview()
            self.imageContainer.removeFromSuperview()
            self.settingsButtonSnapshot?.removeFromSuperview()
            // `transitionWasCancelled` is always false for a button-tap (non-interactive) present, so
            // this preserves existing behaviour; it only differs when an interactive gesture cancels.
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
    }
}

// MARK: - Free-form interactive swipe-up (New Tab Page)

extension FromHomeScreenTransition: SwipeUpInteractiveTransition {

    /// NTP counterpart of the web setup. Reuses `prepareSnapshots` (with the aspect-fill + clip squeeze
    /// fix) and the centered Dax logo, leaving the card at its full-content initial frame. The
    /// interaction controller cross-fades the snapshot out to the `.center` logo as the drag rises, so
    /// the circular logo never squeezes; the snap lands on the same `tabSwitcherCellFrame` end state.
    func prepareInteractivePreview(finalFrame: CGRect) -> SwipeUpInteractivePreview? {
        imageContainer.clipsToBounds = true
        imageContainer.addSubview(imageView)

        guard let homeScreen = mainViewController.newTabPageViewController,
              let tab = mainViewController.tabManager.currentTabsModel.currentTab,
              let rowIndex = tabSwitcherViewController.tabsModel.indexOf(tab: tab),
              let layoutAttr = tabSwitcherViewController.collectionView.layoutAttributesForItem(at: IndexPath(row: rowIndex, section: 0)) else {
            Logger.swipeUpToTabSwitcher.debug("interactive(ntp): missing homeScreen/tab/rowIndex/layoutAttr")
            return nil
        }

        // Pre-scroll so the destination cell is laid out where the card will snap to.
        tabSwitcherViewController.collectionView.scrollToItem(at: IndexPath(row: rowIndex, section: 0),
                                                              at: .centeredVertically, animated: false)

        let theme = ThemeManager.shared.currentTheme
        let initialFrame = adjustFrame(homeScreen.view.convert(homeScreen.rootContainerView.frame, to: nil),
                                       forAddressBarPosition: mainViewController.appSettings.currentAddressBarPosition,
                                       byHeight: -mainViewController.omniBar.barView.expectedHeight)

        solidBackground.frame = initialFrame
        solidBackground.backgroundColor = theme.backgroundColor

        imageContainer.frame = initialFrame
        imageContainer.backgroundColor = theme.backgroundColor

        prepareSnapshots(with: homeScreen,
                         addressBarPosition: mainViewController.appSettings.currentAddressBarPosition,
                         addressBarHeight: mainViewController.omniBar.barView.expectedHeight)

        // Squeeze fix: keep the snapshot's contents proportional (crop, don't stretch) as the container
        // morphs toward the cell aspect ratio. Mirrors the keyframe path's fix.
        homeScreenSnapshot?.contentMode = .scaleAspectFill
        homeScreenSnapshot?.clipsToBounds = true

        imageView.alpha = 0
        imageView.frame = imageContainer.bounds
        imageView.contentMode = .center
        if tabSwitcherSettings.isGridViewEnabled {
            imageView.image = TabViewCell.logoImage(for: tab)
        }

        imageContainer.layer.borderColor = UIColor(designSystemColor: .decorationTertiary).cgColor
        imageContainer.layer.borderWidth = 0
        imageContainer.layer.cornerRadius = 0

        let cellFrame = tabSwitcherCellFrame(for: layoutAttr)
        let destinationImageViewFrame = previewFrame(for: cellFrame.size)

        return SwipeUpInteractivePreview(solidBackground: solidBackground,
                                         imageContainer: imageContainer,
                                         imageView: imageView,
                                         homeScreenSnapshot: homeScreenSnapshot,
                                         initialContainerFrame: initialFrame,
                                         destinationCellFrame: cellFrame,
                                         destinationImageViewFrame: destinationImageViewFrame)
    }
}

class ToHomeScreenTransition: HomeScreenTransition {

    override func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        prepareSubviews(using: transitionContext)
        
        guard let mainViewController = transitionContext.viewController(forKey: .to) as? MainViewController,
              let homeScreen = mainViewController.newTabPageViewController,
              let tab = mainViewController.tabManager.currentTabsModel.currentTab,
              let rowIndex = tabSwitcherViewController.tabsModel.indexOf(tab: tab),
              let layoutAttr = tabSwitcherViewController.collectionView.layoutAttributesForItem(at: IndexPath(row: rowIndex, section: 0))
        else {
            // Layout attributes can be nil when a new tab was just added but the collection view
            // hasn't laid out its cell yet. Fall back to a simple crossfade to avoid a flash.
            if let mainViewController = transitionContext.viewController(forKey: .to) as? MainViewController {
                mainViewController.view.alpha = 1
            }
            UIView.animate(withDuration: TabSwitcherTransition.Constants.duration, animations: {
                self.tabSwitcherViewController.view.alpha = 0
            }, completion: { _ in
                self.solidBackground.removeFromSuperview()
                self.imageContainer.removeFromSuperview()
                transitionContext.completeTransition(true)
            })
            return
        }

        mainViewController.view.alpha = 1
        
        let theme = ThemeManager.shared.currentTheme
        imageContainer.frame = tabSwitcherCellFrame(for: layoutAttr)

        imageContainer.backgroundColor = theme.tabSwitcherCellBackgroundColor
        imageContainer.layer.cornerRadius = TabViewCell.Constants.cellCornerRadius
        
        prepareSnapshots(with: homeScreen, addressBarPosition: mainViewController.appSettings.currentAddressBarPosition, addressBarHeight: mainViewController.omniBar.barView.expectedHeight)
        homeScreenSnapshot?.alpha = 0
        settingsButtonSnapshot?.alpha = 0
        
        imageView.frame = previewFrame(for: imageContainer.bounds.size)
        imageView.contentMode = .center
        if tabSwitcherSettings.isGridViewEnabled {
            imageView.image = TabViewCell.logoImage(for: tab)
            imageView.alpha = tab.viewed ? 1 : 0
        }
        imageView.backgroundColor = .clear

        scrollIfOutsideViewport(collectionView: tabSwitcherViewController.collectionView, rowIndex: rowIndex, attributes: layoutAttr)
        
        UIView.animateKeyframes(withDuration: TabSwitcherTransition.Constants.duration, delay: 0, options: .calculationModeLinear, animations: {
            
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1.0) {
                self.imageContainer.frame = homeScreen.view.convert(homeScreen.rootContainerView.frame, to: nil)
                self.imageContainer.frame = self.adjustFrame(self.imageContainer.frame,
                                                             forAddressBarPosition: mainViewController.appSettings.currentAddressBarPosition,
                                                             byHeight: -mainViewController.omniBar.barView.expectedHeight)
                self.imageContainer.layer.cornerRadius = 0
                self.imageContainer.backgroundColor = theme.backgroundColor
                self.imageView.frame = CGRect(origin: .zero,
                                              size: self.imageContainer.bounds.size)
                self.homeScreenSnapshot?.frame = self.imageContainer.bounds
            }

            if tab.viewed {
                UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.3) {
                    self.imageView.alpha = 0
                    self.imageContainer.alpha = 1
                }
            }

            // Longer transition to create cross fade effect
            UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.8) {
                self.homeScreenSnapshot?.alpha = 1
                self.settingsButtonSnapshot?.alpha = 1
            }
            
            UIView.addKeyframe(withRelativeStartTime: 0.7, relativeDuration: 0.3) {
                self.tabSwitcherViewController.view.alpha = 0
            }
            
        }, completion: { _ in
            self.imageContainer.removeFromSuperview()
            self.settingsButtonSnapshot?.removeFromSuperview()
            transitionContext.completeTransition(true)
        })
    }
}
