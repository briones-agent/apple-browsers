//
//  TabSwitcherPageViewController.swift
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
import Common
import FoundationExtensions
import Core
import DDGSync
import WebKit
import Bookmarks
import Persistence
import os.log
import SwiftUI
import Combine
import DesignResourcesKit
import DesignResourcesKitIcons
import BrowserServicesKit
import PrivacyConfig
import AIChat
import UIComponents
import FoundationModels

protocol TabSwitcherPageDelegate: AnyObject {
    func page(_ page: TabSwitcherPageViewController, didSelectTabAt index: Int)
    func page(_ page: TabSwitcherPageViewController, didDeselectTab: Void)
    func page(_ page: TabSwitcherPageViewController, willDeleteTabs tabs: [Tab], allDeleted: Bool)
    func pageDidDeleteTabs(_ page: TabSwitcherPageViewController, allDeleted: Bool)
    func page(_ page: TabSwitcherPageViewController, didReorderTabs: Void)
    func page(_ page: TabSwitcherPageViewController, contextMenuForTabsAt indexPaths: [IndexPath]) -> UIMenu?
    func page(_ page: TabSwitcherPageViewController, menuForSectionAt section: Int) -> UIMenu?
    func page(_ page: TabSwitcherPageViewController, menuForTopicContainingSection section: Int) -> UIMenu?
    func pageDidRequestDismiss(_ page: TabSwitcherPageViewController)
    func pageCellDidBeginSwipe(_ page: TabSwitcherPageViewController)
    func pageCellDidEndSwipe(_ page: TabSwitcherPageViewController)
    func pageCellDidBeginDrag(_ page: TabSwitcherPageViewController)
    func pageCellDidEndDrag(_ page: TabSwitcherPageViewController)

    var isEditing: Bool { get }
    var isProcessingUpdates: Bool { get set }
    var canDismissOnEmpty: Bool { get }
}

class TabSwitcherPageViewController: UIViewController {
    
    private(set) var collectionView: UICollectionView!
    let tabsModel: TabsModelManaging
    weak var pageDelegate: TabSwitcherPageDelegate?
    var onNewFireTab: (() -> Void)?
    var currentSelection: Int?


    private let browsingMode: BrowsingMode
    private weak var previewsSource: TabPreviewsSource?
    private let tabSwitcherSettings: TabSwitcherSettings
    private var isFireModeEnabled: Bool
    private var tabObserverCancellable: AnyCancellable?
    private var trackerCountViewModel: TabSwitcherTrackerCountViewModel?
    private var trackerCountCancellable: AnyCancellable?
    private var lastAppliedTrackerCountState: TabSwitcherTrackerCountViewModel.State?
    private var trackerInfoModel: InfoPanelView.Model?
    private var fireModeEmptyStateHostingController: UIHostingController<FireModeEmptyStateView>?
    private let duckAIGridContentProvider: DuckAIGridContentProviding?

    var canUpdateCollection = true

    /// Display model for the grid. A single untitled section in flat mode; one section per group when arranged.
    var gridSections: [TabGridSection] = []

    /// On-device activity summaries keyed by section content. An empty string means "generated, but no summary".
    private var sectionSummaries: [String: String] = [:]
    /// Section keys whose summary is currently being generated, so we don't kick off duplicate requests.
    private var summariesInFlight: Set<String> = []

    /// Shared, process-lifetime classification cache so re-opening the switcher doesn't reclassify known domains.
    private var topicCache: TabTopicClassificationCache { .shared }
    /// Guards against overlapping classification passes within this instance.
    private var topicClassificationInFlight = false
    /// True while a coalesced topic reflow is pending, so rapid classification results batch into one reflow.
    private var topicReflowScheduled = false
    /// How long classification results are batched before the grid reflows them together.
    private static let topicReflowInterval: TimeInterval = 1.0

    var selectedIndexPaths: [IndexPath] {
        collectionView.indexPathsForSelectedItems ?? []
    }

    init(browsingMode: BrowsingMode,
         tabsModel: TabsModelManaging,
         previewsSource: TabPreviewsSource,
         tabSwitcherSettings: TabSwitcherSettings,
         trackerCountViewModel: TabSwitcherTrackerCountViewModel?,
         isFireModeEnabled: Bool,
         duckAIGridContentProvider: DuckAIGridContentProviding?) {
        self.browsingMode = browsingMode
        self.tabsModel = tabsModel
        self.previewsSource = previewsSource
        self.tabSwitcherSettings = tabSwitcherSettings
        self.trackerCountViewModel = trackerCountViewModel
        self.isFireModeEnabled = isFireModeEnabled
        self.currentSelection = tabsModel.currentIndex
        self.duckAIGridContentProvider = duckAIGridContentProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = true
        collectionView.isMultipleTouchEnabled = true
        if #available(iOS 17.0, *) {
            collectionView.allowsKeyboardScrolling = false
        }
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.allowsSelection = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsMultipleSelectionDuringEditing = true

        collectionView.register(TabViewGridCell.self, forCellWithReuseIdentifier: TabViewGridCell.reuseIdentifier)
        collectionView.register(TabViewListCell.self, forCellWithReuseIdentifier: TabViewListCell.reuseIdentifier)
        collectionView.register(TabDomainChipsCell.self, forCellWithReuseIdentifier: TabDomainChipsCell.reuseIdentifier)
        collectionView.register(
            TabSwitcherTrackerInfoHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: TabSwitcherTrackerInfoHeaderView.reuseIdentifier
        )
        collectionView.register(
            TabSwitcherSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: TabSwitcherSectionHeaderView.reuseIdentifier
        )
        collectionView.register(
            TabSwitcherTopicHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: TabSwitcherTopicHeaderView.reuseIdentifier
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let backgroundView = UIView(frame: collectionView.frame)
        backgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(gesture:))))
        collectionView.backgroundView = backgroundView
        
        rebuildSections()
        updateDragInteraction()
        subscribeToTabChanges()
        bindTrackerCount()
        trackerCountViewModel?.refresh()
        setupFireModeEmptyState()
    }

    private var lastLayoutSize: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let currentSize = view.bounds.size
        guard currentSize != lastLayoutSize, currentSize != .zero else { return }
        lastLayoutSize = currentSize
        collectionView.collectionViewLayout.invalidateLayout()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        trackerCountViewModel?.refresh()
        reconcileLayoutWithArrangement()
        classifyPendingTopicsIfNeeded()
    }

    /// Ensures the layout matches the current arrangement, e.g. when a page is shown after the
    /// arrangement changed while it was inactive.
    private func reconcileLayoutWithArrangement() {
        let isCompositional = collectionView.collectionViewLayout is UICollectionViewCompositionalLayout
        guard isCompositional != isGrouped else { return }
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        updateDragInteraction()
        reloadData()
    }
    
    private func subscribeToTabChanges() {
        tabObserverCancellable = tabsModel.tabsPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.canUpdateCollection else { return }
                self.reloadData()
            }
    }

    private func setupFireModeEmptyState() {
        guard browsingMode == .fire, isFireModeEnabled else { return }
        let emptyStateView = FireModeEmptyStateView(type: .tabSwitcher(onNewFireTab: { [weak self] in
            Pixel.fire(pixel: .fireModeEmptyStateNewTab)
            self?.onNewFireTab?()
        }))
        let hostingController = UIHostingController(rootView: emptyStateView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        fireModeEmptyStateHostingController = hostingController
    }

    func updateEmptyStateVisibility() {
        guard browsingMode == .fire else { return }
        let shouldShowEmptyState = tabsModel.tabs.isEmpty
        fireModeEmptyStateHostingController?.view.isHidden = !shouldShowEmptyState
        collectionView.isHidden = shouldShowEmptyState
    }

    // MARK: - Tracker Count
    
    private func bindTrackerCount() {
        trackerCountCancellable = trackerCountViewModel?.$state
            .sink { [weak self] state in
                self?.applyTrackerCountState(state)
            }
    }

    private func applyTrackerCountState(_ state: TabSwitcherTrackerCountViewModel.State) {
        guard state != lastAppliedTrackerCountState else { return }
        lastAppliedTrackerCountState = state

        guard state.isVisible else {
            trackerInfoModel = nil
            updateTrackerInfoHeaderIfVisible()
            collectionView.collectionViewLayout.invalidateLayout()
            return
        }

        trackerInfoModel = .trackerInfoPanel(
            state: state,
            onTap: { },
            onInfo: { [weak self] in
                self?.presentHideTrackerCountAlert()
            }
        )
        updateTrackerInfoHeaderIfVisible()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func updateTrackerInfoHeaderIfVisible() {
        let indexPath = IndexPath(item: 0, section: 0)
        guard let header = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: indexPath
        ) as? TabSwitcherTrackerInfoHeaderView else {
            return
        }
        header.configure(in: self, model: trackerInfoModel)
    }

    private func presentHideTrackerCountAlert() {
        let alert = UIAlertController(title: UserText.tabSwitcherTrackerCountHideTitle,
                                      message: UserText.tabSwitcherTrackerCountHideMessage,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: UserText.tabSwitcherTrackerCountKeepAction, style: .cancel))
        alert.addAction(UIAlertAction(title: UserText.tabSwitcherTrackerCountHideAction, style: .default) { [weak self] _ in
            Pixel.fire(pixel: .tabSwitcherTrackerCountHidden)
            self?.trackerCountViewModel?.hide()
        })
        present(alert, animated: true)
    }

    // MARK: - Public API
    
    var selectedTab: Tab? {
        return tabsModel.get(tabAt: currentSelection)
    }

    func reloadData() {
        rebuildSections()
        collectionView.reloadData()
        updateEmptyStateVisibility()
        classifyPendingTopicsIfNeeded()
    }

    func refreshCurrentTabIndicators() {
        guard currentSelection != nil else { return }
        for cell in collectionView.visibleCells {
            guard let tabCell = cell as? TabViewCell,
                  let tab = tabCell.tab else { continue }
            tabCell.isCurrent = isCurrent(tab: tab)
            tabCell.updateCurrentTabBorder()
        }
    }
    
    func scrollToInitialTab() {
        rebuildSections()
        guard let currentTab = tabsModel.currentTab,
              let indexPath = indexPath(for: currentTab),
              indexPath.section < collectionView.numberOfSections,
              indexPath.item < collectionView.numberOfItems(inSection: indexPath.section) else { return }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
    }

    func enterEditingMode() {
        collectionView.reloadData()
    }

    func exitEditingMode(reloadData: Bool) {
        if reloadData {
            collectionView.reloadData()
        }
    }

    func selectAll() {
        for indexPath in allIndexPaths {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    func deselectAll() {
        collectionView.indexPathsForSelectedItems?.forEach {
            collectionView.deselectItem(at: $0, animated: false)
        }
    }

    func deleteTabsAtIndexPaths(_ indexPaths: [IndexPath]) {
        guard let pageDelegate else { return }
        let allTabsDeleted = tabsModel.count == indexPaths.count
        let tabsToClose = indexPaths.compactMap { tab(at: $0) }

        // While grouped, deleting items can empty whole sections; an animated batch
        // update would then mismatch the rebuilt section count, so reload instead.
        if isGrouped {
            pageDelegate.isProcessingUpdates = true
            pageDelegate.page(self, willDeleteTabs: tabsToClose, allDeleted: allTabsDeleted)
            currentSelection = tabsModel.currentIndex
            reloadData()
            pageDelegate.isProcessingUpdates = false
            pageDelegate.pageDidDeleteTabs(self, allDeleted: allTabsDeleted)
            return
        }

        collectionView.performBatchUpdates {
            pageDelegate.isProcessingUpdates = true
            pageDelegate.page(self, willDeleteTabs: tabsToClose, allDeleted: allTabsDeleted)
            rebuildSections()
            collectionView.deleteItems(at: indexPaths)
            currentSelection = tabsModel.currentIndex
            refreshCurrentTabIndicators()
        } completion: { _ in
            pageDelegate.isProcessingUpdates = false
            pageDelegate.pageDidDeleteTabs(self, allDeleted: allTabsDeleted)
        }
    }

    // MARK: - Private

    @objc private func handleBackgroundTap(gesture: UITapGestureRecognizer) {
        guard gesture.tappedInWhitespaceAtEndOfCollectionView(collectionView) else { return }
        pageDelegate?.pageDidRequestDismiss(self)
    }

    /// Resolves the rich-card grid item for `tab`, or `nil` for non-AI tabs and
    /// when no provider is wired in (release builds without an explicit injection).
    /// `nil` keeps the cell on the existing screenshot path.
    private func duckAIGridItem(for tab: Tab) -> DuckAIGridItem? {
        guard tab.isAITab else { return nil }
        return duckAIGridContentProvider?.gridItem(for: tab)
    }
}

// MARK: - Tab grouping / sections

extension TabSwitcherPageViewController {

    /// A domain pill shown under a topic in the topic arrangement.
    struct DomainChip {
        let domain: String
        let count: Int
    }

    struct TabGridSection {
        let title: String?
        let tabs: [Tab]
        /// Whether this section is eligible for an on-device activity summary (the recent recency buckets).
        var summarizable: Bool = false
        /// Topic arrangement only: the topic this section belongs to.
        var topicTitle: String?
        /// Topic arrangement only: total tabs across the whole topic, shown in the topic band header.
        var topicTabCount: Int = 0
        /// Topic arrangement only: when non-nil, this is a topic's chips section (the row of domain pills) rather
        /// than a domain's thumbnail section.
        var chipDomains: [DomainChip]?
        /// The host whose favicon labels this section, when the section represents a single website.
        var faviconHost: String?

        var isTopicChips: Bool { chipDomains != nil }
    }

    /// True when an arrangement is active and the grid is split into titled sections rather than a flat list.
    var isGrouped: Bool {
        tabSwitcherSettings.tabArrangement != nil
    }

    /// Whether the on-device foundation model can be used at all (iOS 26+ with the model available). Gates both
    /// the activity summaries and the topic arrangement.
    var isFoundationModelAvailable: Bool {
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    /// True when tabs are grouped into model-derived topics (each topic further split into domain sections).
    var isTopicArranged: Bool {
        tabSwitcherSettings.tabArrangement == .topic
    }

    /// Whether a domain's thumbnails are revealed. Non-topic arrangements are always "expanded".
    func isDomainExpanded(_ domain: String?) -> Bool {
        guard isTopicArranged, let domain else { return true }
        return topicCache.expandedDomains.contains(domain)
    }

    /// Whether the section's content is currently rendered (chips sections always are; a domain's thumbnail
    /// section only when that domain's chip is expanded).
    func isSectionDisplayed(_ section: Int) -> Bool {
        guard gridSections.indices.contains(section) else { return true }
        let gridSection = gridSections[section]
        if gridSection.isTopicChips { return true }
        guard isTopicArranged, gridSection.topicTitle != nil else { return true }
        return isDomainExpanded(gridSection.title)
    }

    /// Reveals or hides a single domain's thumbnails. Domains expand independently; state persists in the cache.
    func toggleDomainExpansion(_ domain: String?) {
        guard let domain else { return }
        if topicCache.expandedDomains.contains(domain) {
            topicCache.expandedDomains.remove(domain)
        } else {
            topicCache.expandedDomains.insert(domain)
        }
        reloadData()
    }

    /// Whether the given section should reserve space for, and show, an activity summary.
    func sectionShowsSummary(_ section: Int) -> Bool {
        guard isFoundationModelAvailable, gridSections.indices.contains(section) else { return false }
        return gridSections[section].summarizable
    }

    func rebuildSections() {
        gridSections = Self.makeSections(tabs: tabsModel.tabs,
                                         arrangement: tabSwitcherSettings.tabArrangement,
                                         domainTopics: topicCache.domainTopics,
                                         attemptedDomains: topicCache.attemptedDomains)
    }

    /// Swaps the layout for the current arrangement and reloads. Call after the arrangement changes.
    func applyArrangementChange() {
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        updateDragInteraction()
        reloadData()
        scrollToInitialTab()
    }

    /// Disables tab dragging entirely while grouped (the order is defined by the arrangement);
    /// restores the platform default when flat.
    func updateDragInteraction() {
        collectionView.dragInteractionEnabled = !isGrouped && UIDevice.current.userInterfaceIdiom == .pad
    }

    func makeLayout() -> UICollectionViewLayout {
        isGrouped ? makeSectionedLayout() : makeFlowLayout()
    }

    private func makeFlowLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 14
        layout.minimumInteritemSpacing = 14
        layout.sectionInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return layout
    }

    /// One horizontally-scrolling row of cards per section, with a section header above each. In the topic
    /// arrangement a topic's chips section instead lays out a wrapping row of domain pills.
    private func makeSectionedLayout() -> UICollectionViewCompositionalLayout {
        return UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else {
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                                                     heightDimension: .absolute(1)))
                return NSCollectionLayoutSection(group: NSCollectionLayoutGroup.horizontal(layoutSize: item.layoutSize, subitems: [item]))
            }
            let isChips = self.gridSections.indices.contains(sectionIndex) && self.gridSections[sectionIndex].isTopicChips
            if isChips {
                return self.makeChipsSection(sectionIndex: sectionIndex)
            }
            return self.makeCardsSection(sectionIndex: sectionIndex, environment: environment)
        }
    }

    /// A wrapping (multi-line) flow of domain pills, with the topic band as the section header.
    /// A single self-sizing cell that wraps all of a topic's domain pills, below the topic band header. The cell
    /// owns the wrapping so each pill sizes to its own content — no externally-measured frames to drift.
    private func makeChipsSection(sectionIndex: Int) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                          heightDimension: .estimated(TabDomainChipsCell.pillHeight))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 10, trailing: 14)
        addHeader(to: section, forSection: sectionIndex)
        return section
    }

    /// A horizontally-scrolling shelf of card thumbnails (the default for grouped sections).
    private func makeCardsSection(sectionIndex: Int,
                                  environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let containerWidth = environment.container.effectiveContentSize.width
        let cardWidth = min(180, max(130, containerWidth * 0.42))
        let cardHeight = calculateRowHeight(columnWidth: cardWidth)
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(cardWidth), heightDimension: .absolute(cardHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 14
        section.orthogonalScrollingBehavior = .continuous
        // A collapsed domain section renders nothing, so zero its padding to avoid stacking empty slivers.
        section.contentInsets = isSectionDisplayed(sectionIndex)
            ? NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14)
            : .zero
        addHeader(to: section, forSection: sectionIndex)
        return section
    }

    private func addHeader(to section: NSCollectionLayoutSection, forSection sectionIndex: Int) {
        let headerHeight = headerHeight(forSection: sectionIndex)
        guard headerHeight > 0 else { return }
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(headerHeight)),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top)
        section.boundarySupplementaryItems = [header]
    }

    /// The header height for a section: the topic band above a chips row, a domain label above revealed
    /// thumbnails (zero when that domain is collapsed), or the activity-summary header for other arrangements.
    func headerHeight(forSection section: Int) -> CGFloat {
        guard gridSections.indices.contains(section) else { return TabSwitcherSectionHeaderView.height }
        if isTopicArranged {
            let gridSection = gridSections[section]
            if gridSection.isTopicChips {
                return TabSwitcherTopicHeaderView.bandHeight
            }
            return isDomainExpanded(gridSection.title) ? TabSwitcherSectionHeaderView.height : 0
        }
        return sectionShowsSummary(section)
            ? TabSwitcherSectionHeaderView.summarizedHeight
            : TabSwitcherSectionHeaderView.height
    }

    static func makeSections(tabs: [Tab],
                             arrangement: TabArrangement?,
                             domainTopics: [String: String] = [:],
                             attemptedDomains: Set<String> = []) -> [TabGridSection] {
        guard let arrangement else {
            return [TabGridSection(title: nil, tabs: tabs)]
        }
        switch arrangement {
        case .website:
            return makeWebsiteSections(tabs: tabs)
        case .recency:
            return makeRecencySections(tabs: tabs)
        case .topic:
            return makeTopicSections(tabs: tabs, domainTopics: domainTopics, attemptedDomains: attemptedDomains)
        }
    }

    /// A section is summarized only when its hosted-tab count falls in this range. The lower bound skips
    /// single-tab sections (a tab's title is its own summary); the upper bound is the point past which a
    /// 1–3 topic summary can't represent the section and not every tab would fit the model's prompt, so
    /// we summarize all tabs of a section rather than a misleading sample.
    static let summarizableTabCountRange = 2...25

    /// Groups tabs by when they were last viewed into descending time buckets, most-recent first within each.
    /// Recent days are broken out individually — Today, Yesterday, then a bucket per earlier day of the current
    /// week labelled by weekday name — before collapsing into larger windows (previous 7 days, months, older).
    private static func makeRecencySections(tabs: [Tab]) -> [TabGridSection] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOf7Days = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
        let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth) ?? startOfThisMonth

        // Each bucket matches dates on or after its start; checked most-recent first, so a tab lands in exactly one.
        var buckets: [(title: String, start: Date)] = [
            (UserText.tabSwitcherArrangeRecencyToday, startOfToday),
            (UserText.tabSwitcherArrangeRecencyYesterday, startOfYesterday),
        ]

        // One bucket per remaining earlier day of the current week, labelled by weekday name (unambiguous within the week).
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEEE")
        var day = calendar.date(byAdding: .day, value: -1, to: startOfYesterday) ?? startOfYesterday
        while day >= startOfWeek {
            buckets.append((weekdayFormatter.string(from: day), day))
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        buckets.append(contentsOf: [
            (UserText.tabSwitcherArrangeRecencyPrevious7Days, startOf7Days),
            (UserText.tabSwitcherArrangeRecencyThisMonth, startOfThisMonth),
            (UserText.tabSwitcherArrangeRecencyLastMonth, startOfLastMonth),
            (UserText.tabSwitcherArrangeRecencyOlder, .distantPast),
        ])

        var grouped: [[Tab]] = Array(repeating: [], count: buckets.count)
        for tab in tabs {
            // Newly created tabs can briefly have no viewed date; for display purposes they belong with today's activity.
            let date = tab.lastViewedDate ?? now
            let index = buckets.firstIndex { date >= $0.start } ?? buckets.count - 1
            grouped[index].append(tab)
        }

        return buckets.indices.compactMap { index in
            let tabs = grouped[index].sorted { ($0.lastViewedDate ?? now) > ($1.lastViewedDate ?? now) }
            guard !tabs.isEmpty else { return nil }
            // Summarize only sections whose hosted-tab count is in range: enough to be worth it, few enough to fit.
            let hostedTabCount = tabs.filter { ($0.link?.url.host?.droppingWwwPrefix()).map { !$0.isEmpty } ?? false }.count
            return TabGridSection(title: buckets[index].title,
                                  tabs: tabs,
                                  summarizable: Self.summarizableTabCountRange.contains(hostedTabCount))
        }
    }

    private static func makeWebsiteSections(tabs: [Tab]) -> [TabGridSection] {
        var groups: [String: [Tab]] = [:]
        var hostless: [Tab] = []
        for tab in tabs {
            if let host = tab.link?.url.host?.droppingWwwPrefix(), !host.isEmpty {
                groups[host, default: []].append(tab)
            } else {
                hostless.append(tab)
            }
        }
        // Website sections are not summarized: the header already names the domain and its tabs share one topic.
        var sections = groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { TabGridSection(title: $0, tabs: groups[$0] ?? []) }
        // Tabs without a host (e.g. the home tab) collect into a trailing section.
        if !hostless.isEmpty {
            sections.append(TabGridSection(title: UserText.tabSwitcherArrangeOtherSectionTitle, tabs: hostless))
        }
        return sections
    }

    /// Groups tabs into model-derived topics, then sub-groups each topic by domain. Domains not yet classified
    /// collect under a transient "Sorting…" topic until classification lands; domains that were tried but
    /// couldn't be classified fall into "Other".
    private static func makeTopicSections(tabs: [Tab],
                                          domainTopics: [String: String],
                                          attemptedDomains: Set<String>) -> [TabGridSection] {
        let otherTopic = UserText.tabSwitcherArrangeOtherSectionTitle
        let pendingTopic = UserText.tabSwitcherArrangeTopicSorting

        var byDomain: [String: [Tab]] = [:]
        var hostless: [Tab] = []
        for tab in tabs {
            if let host = tab.link?.url.host?.droppingWwwPrefix(), !host.isEmpty {
                byDomain[host, default: []].append(tab)
            } else {
                hostless.append(tab)
            }
        }

        var topicToDomains: [String: [(domain: String, tabs: [Tab])]] = [:]
        for (domain, domainTabs) in byDomain {
            let topic: String
            if let cached = domainTopics[domain] {
                topic = cached
            } else if attemptedDomains.contains(domain) {
                topic = otherTopic
            } else {
                topic = pendingTopic
            }
            topicToDomains[topic, default: []].append((domain, domainTabs))
        }
        if !hostless.isEmpty {
            topicToDomains[otherTopic, default: []].append((otherTopic, hostless))
        }

        func topicTotal(_ topic: String) -> Int {
            (topicToDomains[topic] ?? []).reduce(0) { $0 + $1.tabs.count }
        }
        // Real categories first (most populated on top), then "Other", then the transient "Sorting…" pile at the
        // very bottom so the in-progress churn stays out of the way.
        func rank(_ topic: String) -> Int {
            switch topic {
            case pendingTopic: return 2
            case otherTopic: return 1
            default: return 0
            }
        }
        let orderedTopics = topicToDomains.keys.sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) {
                return rank(lhs) < rank(rhs)
            }
            if topicTotal(lhs) != topicTotal(rhs) {
                return topicTotal(lhs) > topicTotal(rhs)
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        var sections: [TabGridSection] = []
        for topic in orderedTopics {
            let domains = (topicToDomains[topic] ?? []).sorted { lhs, rhs in
                if lhs.tabs.count != rhs.tabs.count {
                    return lhs.tabs.count > rhs.tabs.count
                }
                return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
            }
            let total = topicTotal(topic)
            // A topic leads with its chips row (the domain pills), followed by a thumbnail section per domain
            // (only rendered when that domain's chip is expanded).
            sections.append(TabGridSection(title: topic,
                                           tabs: [],
                                           topicTitle: topic,
                                           topicTabCount: total,
                                           chipDomains: domains.map { DomainChip(domain: $0.domain, count: $0.tabs.count) }))
            for entry in domains {
                let sortedTabs = entry.tabs.sorted { ($0.lastViewedDate ?? .distantPast) > ($1.lastViewedDate ?? .distantPast) }
                // The hostless catch-all entry is titled "Other" rather than a real host, so it gets no favicon.
                let faviconHost = entry.domain == otherTopic ? nil : entry.domain
                sections.append(TabGridSection(title: entry.domain, tabs: sortedTabs, topicTitle: topic, faviconHost: faviconHost))
            }
        }
        return sections
    }

    /// All tabs belonging to the same topic as `section` (across its domain sub-sections), for the topic menu.
    func tabsInSameTopic(asSection section: Int) -> [Tab] {
        guard gridSections.indices.contains(section),
              let topic = gridSections[section].topicTitle else {
            return tabs(inSection: section)
        }
        return gridSections.filter { $0.topicTitle == topic }.flatMap { $0.tabs }
    }

    func tab(at indexPath: IndexPath) -> Tab? {
        guard gridSections.indices.contains(indexPath.section) else { return nil }
        let tabs = gridSections[indexPath.section].tabs
        guard tabs.indices.contains(indexPath.item) else { return nil }
        return tabs[indexPath.item]
    }

    func indexPath(for tab: Tab) -> IndexPath? {
        for (sectionIndex, section) in gridSections.enumerated() {
            if let item = section.tabs.firstIndex(where: { $0 === tab }) {
                return IndexPath(item: item, section: sectionIndex)
            }
        }
        return nil
    }

    /// The index path for a tab only if it is actually rendered right now. Tabs in a collapsed topic section have
    /// no cell, and the collection view may not yet have reloaded to match the model (e.g. a tab opened just before
    /// the switcher is presented). Either way we return `nil` so presentation transitions fall back to a crossfade
    /// rather than scrolling to a non-existent item — which raises an out-of-bounds exception.
    func displayIndexPath(for tab: Tab) -> IndexPath? {
        guard let indexPath = indexPath(for: tab), isSectionDisplayed(indexPath.section) else {
            return nil
        }
        guard indexPath.section < collectionView.numberOfSections,
              indexPath.item < collectionView.numberOfItems(inSection: indexPath.section) else {
            return nil
        }
        return indexPath
    }

    /// Every populated index path across all sections, in display order.
    var allIndexPaths: [IndexPath] {
        gridSections.enumerated().flatMap { sectionIndex, section in
            section.tabs.indices.map { IndexPath(item: $0, section: sectionIndex) }
        }
    }

    func tabs(inSection section: Int) -> [Tab] {
        gridSections.indices.contains(section) ? gridSections[section].tabs : []
    }

    func selectTabs(_ tabs: [Tab]) {
        for tab in tabs {
            guard let indexPath = indexPath(for: tab) else { continue }
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }
}

// MARK: - Section activity summaries

extension TabSwitcherPageViewController {

    /// The summary line to show for a section header: a cached label, a loading placeholder while one
    /// is generated on-device, or nothing when the section isn't summarizable or the model is unavailable.
    func summaryState(for section: TabGridSection?) -> TabSwitcherSectionHeaderView.SummaryState {
        guard let section, section.summarizable else { return .none }

        if #available(iOS 26.0, *), TabSectionActivitySummarizer.isAvailable {
            let key = summaryKey(for: section)
            if let cached = sectionSummaries[key] {
                return cached.isEmpty ? .none : .text(cached)
            }
            let sites = summarySites(for: section)
            guard !sites.isEmpty else { return .none }
            requestSummary(forKey: key, sites: sites)
            return .loading
        }
        return .none
    }

    /// A cache key that stays stable across reloads but changes when the section's set of sites changes,
    /// so the summary is regenerated only when its content actually changes.
    private func summaryKey(for section: TabGridSection) -> String {
        let hosts = section.tabs
            .compactMap { $0.link?.url.host?.droppingWwwPrefix() }
            .sorted()
        return "\(section.title ?? "")|\(hosts.joined(separator: ","))"
    }

    @available(iOS 26.0, *)
    private func summarySites(for section: TabGridSection) -> [TabSectionActivitySummarizer.Site] {
        section.tabs.compactMap { tab in
            guard let url = tab.link?.url,
                  let host = url.host?.droppingWwwPrefix(),
                  !host.isEmpty else { return nil }
            return TabSectionActivitySummarizer.Site(host: host,
                                                     title: tab.link?.displayTitle ?? host,
                                                     detail: Self.readableSlug(from: url))
        }
    }

    /// A short, human-readable hint from a URL path (e.g. "/wiki/Frederic_Tudor" -> "Frederic Tudor"),
    /// used as a fallback signal when a title is vague. Kept to a few words so it stays a hint rather than a
    /// headline to copy. Returns `nil` when the path has no meaningful words. Query strings are intentionally
    /// ignored to avoid feeding tokens or PII into the prompt.
    private static func readableSlug(from url: URL) -> String? {
        let segments = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let last = segments.last else { return nil }
        // Drop a trailing file extension (e.g. ".html").
        let base = last.split(separator: ".").first.map(String.init) ?? last
        let words = base
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { $0.contains(where: { $0.isLetter }) } // drop pure-number / id tokens like "1.12345"
            .prefix(4)                                       // keep it a hint, not the whole headline
        let slug = words.joined(separator: " ")
        // Require a few letters so we skip slugs that are just IDs.
        guard slug.filter({ $0.isLetter }).count >= 3 else { return nil }
        return slug
    }

    @available(iOS 26.0, *)
    private func requestSummary(forKey key: String, sites: [TabSectionActivitySummarizer.Site]) {
        guard !summariesInFlight.contains(key) else { return }
        summariesInFlight.insert(key)
        Task { [weak self] in
            let topics = await TabSectionActivitySummarizer.summarize(sites: sites)
            self?.summariesInFlight.remove(key)
            self?.sectionSummaries[key] = (topics ?? []).joined(separator: " · ")
            self?.refreshSummaryHeader(forKey: key)
        }
    }

    /// Updates any visible header for `key` in place once its summary lands. The header height is fixed for
    /// recency sections, so swapping the text needs no layout invalidation.
    private func refreshSummaryHeader(forKey key: String) {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard gridSections.indices.contains(indexPath.section) else { continue }
            let section = gridSections[indexPath.section]
            guard section.summarizable, summaryKey(for: section) == key,
                  let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? TabSwitcherSectionHeaderView else {
                continue
            }
            let text = sectionSummaries[key] ?? ""
            header.updateSummary(text.isEmpty ? .none : .text(text))
        }
    }
}

// MARK: - Topic classification

extension TabSwitcherPageViewController {

    /// Classifies any not-yet-known domains into topics on-device, biggest domains first, then rebuilds the
    /// grid so their tabs reflow under the right topic. Cheap because it classifies per-domain, not per-tab.
    func classifyPendingTopicsIfNeeded() {
        guard isTopicArranged, isFoundationModelAvailable, !topicClassificationInFlight else { return }
        let pending = pendingTopicDomainSamples()
        guard !pending.isEmpty else { return }

        guard #available(iOS 26.0, *) else { return }
        topicClassificationInFlight = true
        Task { [weak self] in
            // One focused call per domain, biggest first. Results land in the cache as they arrive but the grid
            // reflows on a coalescing timer rather than per result, so many domains settle into their topics
            // together instead of the list jumping on every single result. Cached, so first-seen domains only.
            for entry in pending {
                let topic = await TabDomainTopicClassifier.classify(host: entry.host, sampleTitles: entry.titles)
                guard let self else { return }
                self.topicCache.store(topic.map { [entry.host: $0] } ?? [:], attempted: [entry.host])
                self.scheduleCoalescedReflow()
            }
            self?.topicClassificationInFlight = false
        }
    }

    /// Coalesces classification reflows: results arrive in quick succession, so instead of moving chips on every
    /// result (which makes the list jump), batch them into at most one crossfaded reflow per interval.
    private func scheduleCoalescedReflow() {
        guard !topicReflowScheduled else { return }
        topicReflowScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.topicReflowInterval) { [weak self] in
            guard let self else { return }
            self.topicReflowScheduled = false
            UIView.transition(with: self.collectionView,
                              duration: 0.3,
                              options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.reloadData()
            }
        }
    }

    /// Domains present in the open tabs that haven't been classified or attempted yet, ordered by tab count
    /// (most populated first) with a few sample titles each to disambiguate.
    private func pendingTopicDomainSamples() -> [(host: String, titles: [String])] {
        var domainTabs: [String: [Tab]] = [:]
        for tab in tabsModel.tabs {
            guard let host = tab.link?.url.host?.droppingWwwPrefix(), !host.isEmpty else { continue }
            domainTabs[host, default: []].append(tab)
        }
        return domainTabs.keys
            .filter { topicCache.domainTopics[$0] == nil && !topicCache.attemptedDomains.contains($0) }
            .sorted { (domainTabs[$0]?.count ?? 0) > (domainTabs[$1]?.count ?? 0) }
            .map { host in
                let titles = (domainTabs[host] ?? []).prefix(4).compactMap { $0.link?.displayTitle }
                return (host, Array(titles))
            }
    }
}

// MARK: - UICollectionViewDataSource

extension TabSwitcherPageViewController: UICollectionViewDataSource {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return gridSections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard gridSections.indices.contains(section) else { return 0 }
        let gridSection = gridSections[section]
        // A topic's chips row is one self-sizing cell that wraps all its pills; thumbnails appear per expanded domain.
        if gridSection.isTopicChips { return 1 }
        guard isSectionDisplayed(section) else { return 0 }
        return gridSection.tabs.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if let chips = gridSections[safe: indexPath.section]?.chipDomains {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TabDomainChipsCell.reuseIdentifier, for: indexPath) as? TabDomainChipsCell else {
                return UICollectionViewCell()
            }
            cell.configure(chips: chips, expandedHosts: topicCache.expandedDomains) { [weak self] host in
                self?.toggleDomainExpansion(host)
            }
            return cell
        }

        // Arranged sections are horizontal shelves of cards, so always use the grid cell when grouped.
        let useGridCell = isGrouped || tabSwitcherSettings.isGridViewEnabled
        let cellIdentifier = useGridCell ? TabViewGridCell.reuseIdentifier : TabViewListCell.reuseIdentifier
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellIdentifier, for: indexPath) as? TabViewCell else {
            fatalError("Failed to dequeue cell \(cellIdentifier) as TabViewCell")
        }
        cell.delegate = self
        cell.isDeleting = false
        cell.allowsSwipeToClose = !isGrouped

        if let tab = tab(at: indexPath) {
            tab.removeObserver(self)
            tab.addObserver(self)
            cell.update(withTab: tab,
                        isSelectionModeEnabled: pageDelegate?.isEditing ?? false,
                        preview: previewsSource?.preview(for: tab),
                        isFireModeEnabled: isFireModeEnabled,
                        duckAIGridItem: duckAIGridItem(for: tab),
                        thumbnailLoader: duckAIGridContentProvider)
        }

        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader else {
            return UICollectionReusableView()
        }

        let topicSection = isTopicArranged && gridSections.indices.contains(indexPath.section) ? gridSections[indexPath.section] : nil
        if let topicSection, topicSection.isTopicChips {
            guard let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: TabSwitcherTopicHeaderView.reuseIdentifier,
                for: indexPath
            ) as? TabSwitcherTopicHeaderView else {
                return UICollectionReusableView()
            }
            header.configure(topicTitle: topicSection.topicTitle,
                             topicCount: topicSection.topicTabCount,
                             isPending: topicSection.topicTitle == UserText.tabSwitcherArrangeTopicSorting,
                             topicMenu: pageDelegate?.page(self, menuForTopicContainingSection: indexPath.section))
            return header
        }

        if isGrouped {
            guard let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: TabSwitcherSectionHeaderView.reuseIdentifier,
                for: indexPath
            ) as? TabSwitcherSectionHeaderView else {
                return UICollectionReusableView()
            }
            let section = gridSections.indices.contains(indexPath.section) ? gridSections[indexPath.section] : nil
            header.configure(title: section?.title,
                             count: section?.tabs.count ?? 0,
                             menu: pageDelegate?.page(self, menuForSectionAt: indexPath.section),
                             summary: summaryState(for: section))
            return header
        }

        if isGrouped {
            guard let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: TabSwitcherSectionHeaderView.reuseIdentifier,
                for: indexPath
            ) as? TabSwitcherSectionHeaderView else {
                return UICollectionReusableView()
            }
            let section = gridSections.indices.contains(indexPath.section) ? gridSections[indexPath.section] : nil
            header.configure(title: section?.title,
                             count: section?.tabs.count ?? 0,
                             menu: pageDelegate?.page(self, menuForSectionAt: indexPath.section),
                             summary: summaryState(for: section),
                             faviconHost: section?.faviconHost)
            return header
        }

        guard let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: TabSwitcherTrackerInfoHeaderView.reuseIdentifier,
            for: indexPath
        ) as? TabSwitcherTrackerInfoHeaderView else {
            return UICollectionReusableView()
        }

        header.configure(in: self, model: trackerInfoModel)
        return header
    }
}

// MARK: - UICollectionViewDelegate

extension TabSwitcherPageViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // The chips cell handles its own pill taps internally; ignore selection of the container itself.
        if gridSections[safe: indexPath.section]?.isTopicChips == true {
            collectionView.deselectItem(at: indexPath, animated: false)
            return
        }
        if pageDelegate?.isEditing == true {
            Pixel.fire(pixel: .tabSwitcherTabSelected)
            (collectionView.cellForItem(at: indexPath) as? TabViewCell)?.refreshSelectionAppearance()
            pageDelegate?.page(self, didSelectTabAt: indexPath.row)
        } else {
            currentSelection = tab(at: indexPath).flatMap { tabsModel.indexOf(tab: $0) }
            Pixel.fire(pixel: .tabSwitcherSwitchTabs, withAdditionalParameters: [
                PixelParameters.browsingMode: browsingMode.pixelParamValue
            ])
            if let tab = tab(at: indexPath) {
                if tab.isAITab {
                    DailyPixel.fireDailyAndCount(pixel: .tabManagerSwitchToAITab)
                } else {
                    DailyPixel.fireDailyAndCount(pixel: .tabManagerSwitchToWebTab)
                }
            }
            pageDelegate?.pageDidRequestDismiss(self)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        (collectionView.cellForItem(at: indexPath) as? TabViewCell)?.refreshSelectionAppearance()
        pageDelegate?.page(self, didDeselectTab: ())
        Pixel.fire(pixel: .tabSwitcherTabDeselected)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        return true
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        return !(pageDelegate?.isEditing ?? false) && !isGrouped
    }

    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
                        toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        return proposedIndexPath
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard !indexPaths.isEmpty else { return nil }
        // Domain chips aren't tabs; no long-press menu.
        guard !indexPaths.contains(where: { gridSections[safe: $0.section]?.isTopicChips ?? false }) else { return nil }

        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let modeParam = [PixelParameters.browsingMode: self.browsingMode.pixelParamValue]
            Pixel.fire(pixel: .tabSwitcherLongPress, withAdditionalParameters: modeParam)
            DailyPixel.fire(pixel: .tabSwitcherLongPressDaily, withAdditionalParameters: modeParam)
            return self.pageDelegate?.page(self, contextMenuForTabsAt: indexPaths)
        }
        return configuration
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension TabSwitcherPageViewController: UICollectionViewDelegateFlowLayout {

    private func calculateColumnWidth(minimumColumnWidth: CGFloat, maxColumns: Int) -> CGFloat {
        let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
        let spacing = layout?.sectionInset.left ?? 0.0
        let contentWidth = collectionView.bounds.width - spacing
        let numberOfColumns = min(maxColumns, Int(contentWidth / minimumColumnWidth))
        return contentWidth / CGFloat(numberOfColumns) - spacing
    }

    private func calculateRowHeight(columnWidth: CGFloat) -> CGFloat {
        let contentAspectRatio = collectionView.bounds.width / collectionView.bounds.height
        let heightToFit = (columnWidth / contentAspectRatio) + TabViewCell.Constants.cellHeaderHeight
        let preferredMaxHeight = collectionView.bounds.height / TabSwitcherViewController.Constants.preferredMinNumberOfRows
        let preferredHeight = min(preferredMaxHeight, heightToFit)
        return min(TabSwitcherViewController.Constants.cellMaxHeight,
                   max(TabSwitcherViewController.Constants.cellMinHeight, preferredHeight))
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        if tabSwitcherSettings.isGridViewEnabled {
            let columnWidth = calculateColumnWidth(minimumColumnWidth: 150, maxColumns: 4)
            let rowHeight = calculateRowHeight(columnWidth: columnWidth)
            return CGSize(width: floor(columnWidth), height: floor(rowHeight))
        } else {
            let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            let spacing = layout?.sectionInset.left ?? 0.0
            let width = min(664, collectionView.bounds.size.width - 2 * spacing)
            return CGSize(width: width, height: 70)
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        if isGrouped {
            return CGSize(width: collectionView.bounds.width, height: TabSwitcherSectionHeaderView.height)
        }
        guard trackerInfoModel != nil else { return .zero }
        return CGSize(width: collectionView.bounds.width, height: TabSwitcherTrackerInfoHeaderView.estimatedHeight)
    }
}

// MARK: - TabViewCellDelegate

extension TabSwitcherPageViewController: TabViewCellDelegate {

    func deleteTab(tab: Tab) {
        guard let indexPath = indexPath(for: tab) else { return }
        deleteTabsAtIndexPaths([indexPath])
    }

    func isCurrent(tab: Tab) -> Bool {
        return currentSelection == tabsModel.indexOf(tab: tab)
    }

    func tabViewCellDidBeginSwipe(_ cell: TabViewCell) {
        pageDelegate?.pageCellDidBeginSwipe(self)
    }

    func tabViewCellDidEndSwipe(_ cell: TabViewCell) {
        pageDelegate?.pageCellDidEndSwipe(self)
    }
}

// MARK: - TabObserver

extension TabSwitcherPageViewController: TabObserver {

    func didChange(tab: Tab) {
        guard let indexPath = indexPath(for: tab),
              let cell = collectionView.cellForItem(at: indexPath) as? TabViewCell else {
            return
        }
        guard cell.tab?.uid == tab.uid else {
            DailyPixel.fireDaily(.debugTabSwitcherDidChangeInvalidState)
            return
        }
        cell.update(withTab: tab,
                    isSelectionModeEnabled: pageDelegate?.isEditing ?? false,
                    preview: previewsSource?.preview(for: tab),
                    isFireModeEnabled: isFireModeEnabled,
                    duckAIGridItem: duckAIGridItem(for: tab),
                    thumbnailLoader: duckAIGridContentProvider)
    }
}

// MARK: - UICollectionViewDragDelegate

extension TabSwitcherPageViewController: UICollectionViewDragDelegate {

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        return (pageDelegate?.isEditing ?? false) || isGrouped ? [] : [UIDragItem(itemProvider: NSItemProvider())]
    }

    func collectionView(_ collectionView: UICollectionView, itemsForAddingTo session: any UIDragSession, at indexPath: IndexPath, point: CGPoint) -> [UIDragItem] {
        return [UIDragItem(itemProvider: NSItemProvider())]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionWillBegin session: any UIDragSession) {
        pageDelegate?.pageCellDidBeginDrag(self)
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: any UIDragSession) {
        pageDelegate?.pageCellDidEndDrag(self)
    }
}

// MARK: - UICollectionViewDropDelegate

extension TabSwitcherPageViewController: UICollectionViewDropDelegate {

    func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
        return true
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        return .init(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
        guard !isGrouped else { return }
        guard let destination = coordinator.destinationIndexPath,
              let item = coordinator.items.first,
              let source = item.sourceIndexPath
        else { return }

        collectionView.performBatchUpdates {
            guard let tab = tabsModel.get(tabAt: source.row) else { return }
            tabsModel.move(tab: tab, to: destination.row)
            rebuildSections()
            currentSelection = tabsModel.currentIndex
            collectionView.deleteItems(at: [source])
            collectionView.insertItems(at: [destination])
        } completion: { [weak self] _ in
            guard let self else { return }
            if self.pageDelegate?.isEditing == true {
                self.reloadData()
                collectionView.selectItem(at: destination, animated: true, scrollPosition: [])
            } else {
                collectionView.reloadItems(at: [IndexPath(row: self.currentSelection ?? 0, section: 0)])
            }
            self.pageDelegate?.page(self, didReorderTabs: ())
            coordinator.drop(item.dragItem, toItemAt: destination)
        }
    }
}

// MARK: - UITapGestureRecognizer Helpers

private extension UITapGestureRecognizer {
    
    func tappedInWhitespaceAtEndOfCollectionView(_ collectionView: UICollectionView) -> Bool {
        guard collectionView.indexPathForItem(at: self.location(in: collectionView)) == nil else { return false }
        let location = self.location(in: collectionView)
           
        // Now check if the tap is in the whitespace area at the end
        let lastSection = collectionView.numberOfSections - 1
        let lastItemIndex = collectionView.numberOfItems(inSection: lastSection) - 1
        
        // Get the frame of the last item
        // If there are no items in the last section, the entire area is whitespace
       guard lastItemIndex >= 0 else { return true }
        
        let lastItemIndexPath = IndexPath(item: lastItemIndex, section: lastSection)
        let lastItemFrame = collectionView.layoutAttributesForItem(at: lastItemIndexPath)?.frame ?? .zero
        
        // Check if the tap is below the last item.
        // Add 10px buffer to ensure it's whitespace.
        if location.y > lastItemFrame.maxY + 15 // below the bottom of the last item is definitely the end
            || (location.x > lastItemFrame.maxX + 15 && location.y > lastItemFrame.minY) { // to the right of the last item is the end as long as it's also at least below the start of the frame
            // The tap is in the whitespace area at the end
        return true
    }

        return false
    }
}

// MARK: - Section header

/// Section header shown above each group of tabs when the tab switcher grid is arranged.
final class TabSwitcherSectionHeaderView: UICollectionReusableView {

    static let reuseIdentifier = "TabSwitcherSectionHeaderView"
    /// Height for a single-line header (title only).
    static let height: CGFloat = 36
    /// Height for a header that reserves room for the activity summary (up to two lines of topics).
    static let summarizedHeight: CGFloat = 62

    /// The optional activity line shown under the section title.
    enum SummaryState {
        case none
        case loading
        case text(String)
    }

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .daxFootnoteSemibold()
        label.textColor = UIColor(designSystemColor: .textSecondary)
        return label
    }()

    private let summaryLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .daxCaption()
        label.textColor = UIColor(designSystemColor: .textTertiary)
        label.numberOfLines = 2
        return label
    }()

    private let faviconView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 3
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        return imageView
    }()

    private let menuButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(DesignSystemImages.Glyphs.Size24.moreApple, for: .normal)
        button.tintColor = UIColor(designSystemColor: .iconsSecondary)
        button.showsMenuAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let rowStack = UIStackView(arrangedSubviews: [faviconView, textStack])
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rowStack)
        addSubview(menuButton)
        NSLayoutConstraint.activate([
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),

            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rowStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),

            menuButton.leadingAnchor.constraint(greaterThanOrEqualTo: rowStack.trailingAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    func configure(title: String?, count: Int, menu: UIMenu?, summary: SummaryState = .none, faviconHost: String? = nil) {
        if let title {
            titleLabel.text = "\(title) · \(count)"
        } else {
            titleLabel.text = nil
        }
        if let faviconHost {
            faviconView.isHidden = false
            faviconView.loadFavicon(forDomain: faviconHost, usingCache: .tabs)
        } else {
            faviconView.isHidden = true
            faviconView.image = nil
        }
        menuButton.menu = menu
        menuButton.isHidden = menu == nil
        updateSummary(summary)
    }

    func updateSummary(_ summary: SummaryState) {
        switch summary {
        case .none:
            summaryLabel.text = nil
            summaryLabel.isHidden = true
        case .loading:
            summaryLabel.text = UserText.tabSwitcherArrangeRecencySummarizing
            summaryLabel.isHidden = false
        case .text(let value):
            summaryLabel.text = value
            summaryLabel.isHidden = false
        }
    }
}

// MARK: - Activity summarizer

/// Generates a short, human-readable label describing the browsing activity represented by a group of
/// tabs, using Apple's on-device foundation model. Everything runs on-device: tab titles and hosts are
/// never sent off the device.
@available(iOS 26.0, *)
enum TabSectionActivitySummarizer {

    /// A site feeding the summary: the host (site name), its page title, and an optional readable
    /// slug pulled from the URL path for extra signal when the title is vague.
    struct Site: Sendable {
        let host: String
        let title: String
        let detail: String?
    }

    @Generable
    struct ActivitySummary {
        @Guide(description: "One to three short labels for what the tabs are about, ordered most prominent first. Each is a concise 2 to 4 word paraphrase of the topic in your own words — never a page title copied or lightly edited, and never a single generic category word. Drop site names and boilerplate such as 'Log In' or 'Thank You For Your Order'. One label per distinct topic; never repeat one. No trailing punctuation.", .count(1...3))
        var activities: [String]
    }

    /// Upper bound on tabs fed to a single summary. Matches the section cutoff so a summarized section's tabs
    /// all fit the prompt — the summary reflects the whole section, never a misleading sample.
    private static let maxSites = TabSwitcherPageViewController.summarizableTabCountRange.upperBound

    private static let instructions = """
    You label what a group of open browser tabs are about, from each tab's page title (plus a parenthetical \
    address hint). For each topic write a short 2 to 4 word phrase IN YOUR OWN WORDS that captures it. Two \
    rules pull in opposite directions — respect both: (1) do not copy or lightly reword a page title; \
    describe the underlying topic instead. (2) do not shrink it to a single broad category word like News, \
    Shopping, or Tech; keep it specific. Strip away site names, domains, and boilerplate such as \
    "Log In to My Account" or "Thank You For Your Order". Merge tabs about the same topic into one label and \
    add another only for a clearly different topic; never repeat a topic, and never copy the address hint verbatim.
    """

    /// Whether the on-device model is ready to use right now (device eligible, Apple Intelligence enabled, model downloaded).
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Returns short topic labels describing the given sites, or `nil` if the model is unavailable, there is
    /// nothing to summarize, or generation fails.
    static func summarize(sites: [Site]) async -> [String]? {
        guard SystemLanguageModel.default.isAvailable, !sites.isEmpty else { return nil }

        let lines = sites.prefix(maxSites)
            .map { site -> String in
                guard let detail = site.detail, !detail.isEmpty else {
                    return "- \(site.title) — \(site.host)"
                }
                return "- \(site.title) — \(site.host) (\(detail))"
            }
            .joined(separator: "\n")
        let prompt = "These tabs are open together:\n\(lines)"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: ActivitySummary.self)
            let activities = response.content.activities
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return activities.isEmpty ? nil : activities
        } catch {
            Logger.general.error("Tab section activity summary failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Topic header

/// The topic band shown above a topic's row of domain chips: an emoji, the topic name and total count, and a
/// topic menu. While a topic is still being classified it shows a spinner instead of an emoji.
final class TabSwitcherTopicHeaderView: UICollectionReusableView {

    static let reuseIdentifier = "TabSwitcherTopicHeaderView"
    static let bandHeight: CGFloat = 48

    private let topicLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .daxBodyBold()
        label.textColor = UIColor(designSystemColor: .textPrimary)
        return label
    }()

    private let spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.hidesWhenStopped = true
        return view
    }()

    private let menuButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(DesignSystemImages.Glyphs.Size24.moreApple, for: .normal)
        button.tintColor = UIColor(designSystemColor: .iconsSecondary)
        button.showsMenuAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(topicLabel)
        addSubview(spinner)
        addSubview(menuButton)

        let labelTrailing = topicLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -8)
        labelTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            topicLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            topicLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            topicLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            labelTrailing,

            spinner.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: topicLabel.centerYAnchor),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            menuButton.centerYAnchor.constraint(equalTo: topicLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    func configure(topicTitle: String?, topicCount: Int, isPending: Bool, topicMenu: UIMenu?) {
        if let topicTitle {
            let prefix = isPending ? "" : "\(Self.emoji(forTopic: topicTitle)) "
            topicLabel.text = "\(prefix)\(topicTitle) · \(topicCount)"
        } else {
            topicLabel.text = nil
        }
        if isPending {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        menuButton.menu = topicMenu
        menuButton.isHidden = topicMenu == nil
    }

    private static func emoji(forTopic topic: String) -> String {
        switch topic {
        case "Shopping": return "🛒"
        case "Food & Drink": return "🍽️"
        case "Travel": return "✈️"
        case "News": return "📰"
        case "Entertainment": return "🎬"
        case "Games": return "🎮"
        case "Sports": return "🏅"
        case "Finance": return "💰"
        case "Business": return "💼"
        case "Education": return "🎓"
        case "Reference": return "📚"
        case "Health & Fitness": return "💪"
        case "Social": return "💬"
        case "Technology": return "💻"
        default: return "🗂️"
        }
    }
}

// MARK: - Domain chips

/// A single self-sizing cell that wraps a topic's domain pills onto as many lines as needed. It owns the wrapping
/// layout, so each pill sizes to its own content and the cell reports its own height — no externally-measured
/// frames that can drift out of sync with the pills.
final class TabDomainChipsCell: UICollectionViewCell {

    static let reuseIdentifier = "TabDomainChipsCell"
    static let pillHeight: CGFloat = 30
    private static let interItemSpacing: CGFloat = 8
    private static let lineSpacing: CGFloat = 8

    private var pills: [DomainPillView] = []
    private var onTap: ((String) -> Void)?

    func configure(chips: [TabSwitcherPageViewController.DomainChip], expandedHosts: Set<String>, onTap: @escaping (String) -> Void) {
        self.onTap = onTap
        pills.forEach { $0.removeFromSuperview() }
        pills = chips.map { chip in
            let pill = DomainPillView()
            pill.configure(text: "\(chip.domain) · \(chip.count)", host: chip.domain, isExpanded: expandedHosts.contains(chip.domain))
            let host = chip.domain
            pill.addAction(UIAction { [weak self] _ in self?.onTap?(host) }, for: .touchUpInside)
            contentView.addSubview(pill)
            return pill
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPills(width: contentView.bounds.width, apply: true)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes.frame.size.height = layoutPills(width: layoutAttributes.size.width, apply: false)
        return layoutAttributes
    }

    @discardableResult
    private func layoutPills(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0 else { return Self.pillHeight }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for pill in pills {
            let pillWidth = min(pill.intrinsicContentSize.width, width)
            if x > 0, x + pillWidth > width {
                x = 0
                y += Self.pillHeight + Self.lineSpacing
            }
            if apply {
                pill.frame = CGRect(x: x, y: y, width: pillWidth, height: Self.pillHeight)
            }
            x += pillWidth + Self.interItemSpacing
        }
        return pills.isEmpty ? Self.pillHeight : y + Self.pillHeight
    }
}

/// A tappable pill for one website within a topic, showing its favicon. Sizes to its own content.
final class DomainPillView: UIControl {

    private static let horizontalPadding: CGFloat = 12
    private static let faviconSize: CGFloat = 16
    private static let faviconSpacing: CGFloat = 6

    private let faviconView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 3
        imageView.isUserInteractionEnabled = false
        return imageView
    }()

    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .daxCaption()
        label.isUserInteractionEnabled = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        addSubview(faviconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: Self.faviconSize),
            faviconView.heightAnchor.constraint(equalToConstant: Self.faviconSize),

            label.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: Self.faviconSpacing),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    func configure(text: String, host: String, isExpanded: Bool) {
        label.text = text
        faviconView.loadFavicon(forDomain: host, usingCache: .tabs)
        if isExpanded {
            backgroundColor = UIColor(designSystemColor: .accent)
            layer.borderColor = UIColor.clear.cgColor
            label.textColor = UIColor(designSystemColor: .surface)
        } else {
            backgroundColor = UIColor(designSystemColor: .surface)
            layer.borderColor = UIColor(designSystemColor: .lines).cgColor
            label.textColor = UIColor(designSystemColor: .textPrimary)
        }
    }

    override var intrinsicContentSize: CGSize {
        let width = Self.horizontalPadding + Self.faviconSize + Self.faviconSpacing
            + label.intrinsicContentSize.width + Self.horizontalPadding
        return CGSize(width: width, height: TabDomainChipsCell.pillHeight)
    }
}

// MARK: - Topic classification cache

/// Process-lifetime, in-memory cache of website → topic classifications, shared across tab switcher instances so
/// re-opening the switcher (e.g. after navigating between tabs) doesn't reclassify domains it already knows.
/// Intentionally not persisted to disk — it's derived browsing data and cheap to rebuild on next launch.
@MainActor
final class TabTopicClassificationCache {

    static let shared = TabTopicClassificationCache()

    private init() {}

    private(set) var domainTopics: [String: String] = [:]
    /// Domains already attempted (including failures), so we don't retry them every time the grid rebuilds.
    private(set) var attemptedDomains: Set<String> = []
    /// Domains (hosts) whose chips are expanded; persisted so expansion survives navigating between tabs.
    var expandedDomains: Set<String> = []

    func store(_ classifications: [String: String], attempted: [String]) {
        domainTopics.merge(classifications) { _, new in new }
        attemptedDomains.formUnion(attempted)
    }
}

// MARK: - Topic classifier

/// Classifies a website into one App Store–style category using Apple's on-device foundation model. One focused
/// call per domain (a domain almost always maps to one category), so results are accurate and cache well.
/// Everything runs on-device.
@available(iOS 26.0, *)
enum TabDomainTopicClassifier {

    /// The allowed categories. Kept in sync with the inline list in the @Guide below and the header's emoji map.
    static let categories = ["Shopping", "Food & Drink", "Travel", "News", "Entertainment", "Games", "Sports",
                             "Finance", "Business", "Education", "Reference", "Health & Fitness", "Social",
                             "Technology", "Other"]

    @Generable
    struct Classification {
        @Guide(description: "The single best-fitting category for this website.",
               .anyOf(["Shopping", "Food & Drink", "Travel", "News", "Entertainment", "Games", "Sports",
                       "Finance", "Business", "Education", "Reference", "Health & Fitness", "Social",
                       "Technology", "Other"]))
        var category: String
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    private static let instructions = """
    You assign a website to exactly one category from this list: Shopping, Food & Drink, Travel, News, \
    Entertainment, Games, Sports, Finance, Business, Education, Reference, Health & Fitness, Social, Technology, \
    Other. Decide from the domain and its example page titles. Guidance: an online store → Shopping; restaurants \
    or food delivery → Food & Drink; flights or hotels → Travel; a newspaper or current events → News; movies, \
    TV or celebrities → Entertainment; video games → Games; a bank or investing → Finance; a company or work \
    tool → Business; courses or schools → Education; encyclopedias, wikis, docs or government info → Reference; \
    gadgets, software or tech blogs → Technology; a social network → Social. Use Other only when nothing fits.
    """

    /// The best-fitting category for a single website, or `nil` if the model is unavailable or generation fails.
    static func classify(host: String, sampleTitles: [String]) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let titles = sampleTitles.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")
        let prompt = titles.isEmpty
            ? "Website: \(host)\nWhich category fits best?"
            : "Website: \(host)\nExample pages: \(titles)\nWhich category fits best?"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: Classification.self)
            let category = response.content.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return categories.contains(category) ? category : nil
        } catch {
            Logger.general.error("Tab domain topic classification failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
