//
//  WebViewTransition.swift
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

class WebViewTransition: TabSwitcherTransition {
    
    fileprivate let tabSwitcherSettings: TabSwitcherSettings = DefaultTabSwitcherSettings()
    
    fileprivate func tabSwitcherCellFrame(for attributes: UICollectionViewLayoutAttributes) -> CGRect {
        return self.tabSwitcherViewController.collectionView.convert(attributes.frame,
                                                                     to: self.tabSwitcherViewController.view)
    }
    
    fileprivate func previewFrame(for cellBounds: CGSize, preview: UIImage) -> CGRect {
        guard tabSwitcherSettings.isGridViewEnabled else {
            return CGRect(origin: .zero, size: cellBounds)
        }
        
        let previewAspectRatio = preview.size.height / preview.size.width
        let containerAspectRatio = (cellBounds.height - TabViewCell.Constants.cellHeaderHeight) / cellBounds.width
        let strechedVerically = containerAspectRatio < previewAspectRatio
        
        var targetSize = CGSize.zero
        if strechedVerically {
            targetSize.width = cellBounds.width
            targetSize.height = cellBounds.width * previewAspectRatio
        } else {
            targetSize.height = cellBounds.height - TabViewCell.Constants.cellHeaderHeight
            targetSize.width = targetSize.height / previewAspectRatio
        }
        
        let targetFrame = CGRect(x: 0,
                                 y: TabViewCell.Constants.cellHeaderHeight,
                                 width: targetSize.width,
                                 height: targetSize.height - 8)
            .insetBy(dx: 4, dy: 4)
        return targetFrame
    }
}

class FromWebViewTransition: WebViewTransition {
    
    private let mainViewController: MainViewController
    
    init(mainViewController: MainViewController,
         tabSwitcherViewController: TabSwitcherViewController) {
        self.mainViewController = mainViewController

        super.init(tabSwitcherViewController: tabSwitcherViewController)
    }
    
    override func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        prepareSubviews(using: transitionContext)
        
        tabSwitcherViewController.view.alpha = 0
        transitionContext.containerView.insertSubview(tabSwitcherViewController.view, aboveSubview: solidBackground)
        tabSwitcherViewController.view.frame = transitionContext.finalFrame(for: tabSwitcherViewController)
        tabSwitcherViewController.prepareForPresentation()
        
        guard let webView = mainViewController.currentTab?.webView,
              let tab = mainViewController.tabManager.currentTabsModel.currentTab,
              let rowIndex = tabSwitcherViewController.tabsModel.indexOf(tab: tab)
        else {
            tabSwitcherViewController.view.alpha = 1
            transitionContext.completeTransition(true)
            return
        }

        let indexPath = IndexPath(row: rowIndex, section: 0)
        tabSwitcherViewController.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)

        guard let layoutAttr = tabSwitcherViewController.collectionView.layoutAttributesForItem(at: indexPath),
              let preview = tabSwitcherViewController.previewsSource.preview(for: tab)
        else {
            tabSwitcherViewController.view.alpha = 1
            transitionContext.completeTransition(true)
            return
        }

        let theme = ThemeManager.shared.currentTheme
        let webViewFrame = webView.convert(webView.bounds, to: nil)
        
        solidBackground.backgroundColor = theme.backgroundColor
        solidBackground.frame = webViewFrame
        
        imageContainer.frame = mainViewController.viewCoordinator.contentContainer.frame
        imageContainer.frame = adjustFrame(imageContainer.frame,
                                           forAddressBarPosition: mainViewController.appSettings.currentAddressBarPosition,
                                           byHeight: -mainViewController.omniBar.barView.expectedHeight)
        imageView.frame = imageContainer.bounds
        imageView.image = preview

        // Ramp a border in lockstep with the corner radius (see keyframe below) so a white page
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
                self.imageView.frame = self.previewFrame(for: containerFrame.size, preview: preview)
            }
            
            UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) {
                self.tabSwitcherViewController.view.alpha = 1
            }
            
            if !self.tabSwitcherSettings.isGridViewEnabled {
                UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.5) {
                    self.imageView.alpha = 0
                }
            }
        }, completion: { _ in
            self.solidBackground.removeFromSuperview()
            self.imageContainer.removeFromSuperview()
            // `transitionWasCancelled` is always false for a button-tap (non-interactive) present, so
            // this preserves existing behaviour; it only differs when an interactive gesture cancels.
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })

    }
}

// MARK: - Free-form interactive swipe-up (web page)

extension FromWebViewTransition: SwipeUpInteractiveTransition {

    /// Builds the same page-preview card the keyframe path animates, but leaves it at its full-content
    /// initial frame for the interaction controller to drag freely. Reuses `adjustFrame` +
    /// `tabSwitcherCellFrame` + `previewFrame` so the snap on commit lands pixel-identical to the
    /// button-tap end state.
    func prepareInteractivePreview(finalFrame: CGRect) -> SwipeUpInteractivePreview? {
        imageContainer.clipsToBounds = true
        imageContainer.addSubview(imageView)

        guard let webView = mainViewController.currentTab?.webView,
              let tab = mainViewController.tabManager.currentTabsModel.currentTab,
              let rowIndex = tabSwitcherViewController.tabsModel.indexOf(tab: tab) else {
            Logger.swipeUpToTabSwitcher.debug("interactive(web): missing webView/tab/rowIndex")
            return nil
        }

        let indexPath = IndexPath(row: rowIndex, section: 0)
        tabSwitcherViewController.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)

        guard let layoutAttr = tabSwitcherViewController.collectionView.layoutAttributesForItem(at: indexPath),
              let preview = tabSwitcherViewController.previewsSource.preview(for: tab) else {
            Logger.swipeUpToTabSwitcher.debug("interactive(web): missing layoutAttr/preview")
            return nil
        }

        let theme = ThemeManager.shared.currentTheme
        let webViewFrame = webView.convert(webView.bounds, to: nil)
        solidBackground.backgroundColor = theme.backgroundColor
        solidBackground.frame = webViewFrame

        var initialFrame = mainViewController.viewCoordinator.contentContainer.frame
        initialFrame = adjustFrame(initialFrame,
                                   forAddressBarPosition: mainViewController.appSettings.currentAddressBarPosition,
                                   byHeight: -mainViewController.omniBar.barView.expectedHeight)
        imageContainer.frame = initialFrame
        imageView.frame = imageContainer.bounds
        imageView.image = preview

        imageContainer.layer.borderColor = UIColor(designSystemColor: .decorationTertiary).cgColor
        imageContainer.layer.borderWidth = 0
        imageContainer.layer.cornerRadius = 0

        let cellFrame = tabSwitcherCellFrame(for: layoutAttr)
        let destinationImageViewFrame = previewFrame(for: cellFrame.size, preview: preview)

        return SwipeUpInteractivePreview(solidBackground: solidBackground,
                                         imageContainer: imageContainer,
                                         imageView: imageView,
                                         homeScreenSnapshot: nil,
                                         initialContainerFrame: initialFrame,
                                         destinationCellFrame: cellFrame,
                                         destinationImageViewFrame: destinationImageViewFrame)
    }
}

class ToWebViewTransition: WebViewTransition {

    override func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        prepareSubviews(using: transitionContext)
        
        guard let mainViewController = transitionContext.viewController(forKey: .to) as? MainViewController,
              let webView = mainViewController.currentTab?.webView,
              let tab = mainViewController.currentTab?.tabModel,
              let rowIndex = tabSwitcherViewController.tabsModel.indexOf(tab: tab),
              let layoutAttr = tabSwitcherViewController.collectionView.layoutAttributesForItem(at: IndexPath(row: rowIndex, section: 0))
        else {
            // Crossfade fallback when destination is no longer a web view; mirrors ToHomeScreenTransition.
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
                
        let theme = ThemeManager.shared.currentTheme
        let webViewFrame = webView.convert(webView.bounds, to: nil)
        mainViewController.view.alpha = 1
        
        solidBackground.backgroundColor = theme.backgroundColor
        solidBackground.frame = webView.bounds
        // Put overlay above webview to hide its content till the end of the transition
        solidBackground.removeFromSuperview()
        webView.addSubview(solidBackground)
        
        imageContainer.frame = tabSwitcherCellFrame(for: layoutAttr)
        imageContainer.layer.cornerRadius = TabViewCell.Constants.cellCornerRadius
        
        let preview = tabSwitcherViewController.previewsSource.preview(for: tab)
        if let preview = preview {
            imageView.frame = previewFrame(for: imageContainer.bounds.size,
                                           preview: preview)
        } else {
            imageView.frame = CGRect(origin: .zero, size: imageContainer.bounds.size)
        }
        imageView.image = preview
        
        if !tabSwitcherSettings.isGridViewEnabled {
            self.imageView.alpha = 0
        }
        
        scrollIfOutsideViewport(collectionView: tabSwitcherViewController.collectionView, rowIndex: rowIndex, attributes: layoutAttr)
        
        UIView.animate(withDuration: TabSwitcherTransition.Constants.duration, animations: {
            self.imageContainer.frame = mainViewController.viewCoordinator.contentContainer.frame
            self.imageContainer.layer.cornerRadius = 0

            self.imageView.frame = self.destinationImageFrame(for: webViewFrame.size,
                                                              preview: preview)
            self.imageView.alpha = 1
            
            self.solidBackground.alpha = 1
            self.tabSwitcherViewController.view.alpha = 0
        }, completion: { _ in
            self.solidBackground.removeFromSuperview()
            self.imageContainer.removeFromSuperview()
            transitionContext.completeTransition(true)
        })
    }
    
    private func destinationImageFrame(for containerSize: CGSize,
                                       preview: UIImage?) -> CGRect {
        guard let preview = preview else {
            return CGRect(origin: .zero, size: containerSize)
        }
        
        let targetFrame = CGRect(x: 0,
                                 y: 0,
                                 width: containerSize.width,
                                 height: containerSize.width * (preview.size.height / preview.size.width))
        return targetFrame
    }

}
