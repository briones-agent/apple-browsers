//
//  OnboardingView+DuckAIExperimentSearchContent.swift
//  DuckDuckGo
//
//  Copyright © 2024 DuckDuckGo. All rights reserved.
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

import DesignResourcesKit
import DesignResourcesKitIcons
import DuckUI
import Onboarding
import QuartzCore
import SwiftUI
import UIComponents
import UIKit

extension OnboardingView {
    private enum Metrics {
        // MARK: Spacing
        static let contentVerticalSpacing: CGFloat = 16
        static let legacyTitleToPickerTopPadding: CGFloat = 8
        static let rebrandedTitleToPickerTopPadding: CGFloat = 16
        static let fieldToFirstChipTopPadding: CGFloat = 16
        static let interChipSpacing: CGFloat = 8
        static let queryFieldBottomPadding: CGFloat = -8
        static let queryFieldTopPadding: CGFloat = -12
        static let queryFieldContentSpacing: CGFloat = 8
        static let queryFieldHorizontalPadding: CGFloat = 16
        static let queryFieldVerticalPadding: CGFloat = 16.33
        static let suggestionChipLeadingPadding: CGFloat = 14
        static let suggestionChipTrailingPadding: CGFloat = 16
        static let suggestionChipContentSpacing: CGFloat = 8
        static let disabledPrimaryActionOpacity: CGFloat = 0.3

        // MARK: Sizing
        static let pickerWidth: CGFloat = 216
        static let pickerHeight: CGFloat = 38
        static let pickerContainerHeight: CGFloat = 40
        static let pickerVerticalPadding: CGFloat = 0.5
        static let pickerBottomPadding: CGFloat = 4
        static let singleLineFieldHeight: CGFloat = 26
        static let multilineFieldHeight: CGFloat = 56
        static let legacyChipHeight: CGFloat = 32
        static let rebrandedChipHeight: CGFloat = 32
        static let queryFieldActionButtonSize: CGFloat = 28
        static let queryFieldCornerRadius: CGFloat = 14
        static let queryFieldInnerBorderInset: CGFloat = 2
        static let suggestionChipIconSize: CGFloat = 16
        static let maxSuggestionCount = 3
        static let legacyChipCornerRadius: CGFloat = 12
        static let rebrandedChipCornerRadius: CGFloat = 32
        static let legacyQueryFieldBorderWidth: CGFloat = 2
        static let rebrandedQueryFieldBorderWidth: CGFloat = 1
        static let legacySuggestionChipBorderWidth: CGFloat = 1
        static let rebrandedSuggestionChipBorderWidth: CGFloat = 1.5

        // MARK: Animation
        static let initialToggleStartDelay: TimeInterval = 0.35
        static let legacyInitialInputFocusDelayAfterAppear: TimeInterval = 0.35
        static let rebrandedInitialInputFocusDelayAfterAppear: TimeInterval = 0.55
        static let suggestionInitialRevealDelay: TimeInterval = 1
        static let suggestionRevealFallbackDelayAfterFocus: TimeInterval = 0.4
        static let pickerSelectionAnimationDuration: TimeInterval = 0.22
        static let contentFadeAnimationDuration: TimeInterval = 0.2
        static let suggestionTransitionScale: CGFloat = 0.96
        static let suggestionSpringMass: CGFloat = 0.7
        static let suggestionSpringStiffness: CGFloat = 180
        static let suggestionSpringDamping: CGFloat = 14
        static let suggestionSpringInitialVelocity: CGFloat = 0.25

        // MARK: Offset
        static let queryFieldActionOffsetX: CGFloat = 2.33
        static let queryFieldActionOffsetY: CGFloat = 1
    }

    struct DuckAIExperimentSearchContent: View {
        // MARK: Types
        enum VisualStyle {
            case legacy
            case rebranded
        }

        // MARK: Dependencies
        @Environment(\.onboardingTheme) private var onboardingTheme
        private let action: (OnboardingIntroViewModel.DuckAIExperimentSelection) -> Void
        private let openAIChatAction: (String?, Bool) -> Void
        private let openSearchAction: (String) -> Void
        private let measureQuerySubmissionAction: (Bool, DuckAIQueryExperimentPromptSource) -> Void
        private let startExitTransitionAction: () -> Void
        private let visualStyle: VisualStyle
        @StateObject private var pickerViewModel: ImageSegmentedPickerViewModel

        // MARK: State
        @State private var query = ""
        @State private var isDuckAISelected: Bool
        @State private var isInputFocused = false
        @State private var visibleSuggestionCount = 0
        @State private var didRunInitialToggleAnimation = false
        @State private var isTransitioningOut = false
        @State private var isRunningInitialSelectionAnimation = false
        @State private var suggestionSequenceStarted = false
        @State private var hasPassedInitialFocusDelay = false
        @State private var shouldFocusWhenInitialDelayPasses = false
        private let shouldAnimateToDuckAIOnAppear: Bool

        // MARK: Constants
        private static let pickerItems: [ImageSegmentedPickerItem] = [
            ImageSegmentedPickerItem(
                text: UserText.searchInputToggleSearchButtonTitle,
                selectedImage: Image(uiImage: DesignSystemImages.Glyphs.Size16.findSearchGradientColor),
                unselectedImage: Image(uiImage: DesignSystemImages.Glyphs.Size16.findSearch)
            ),
            ImageSegmentedPickerItem(
                text: UserText.searchInputToggleAIChatButtonTitle,
                selectedImage: Image(uiImage: DesignSystemImages.Glyphs.Size16.aiChatGradientColor),
                unselectedImage: Image(uiImage: DesignSystemImages.Glyphs.Size16.aiChat)
            )
        ]

        init(
            defaultExperience: OnboardingIntroStep.DuckAIExperimentDefaultExperience,
            visualStyle: VisualStyle = .legacy,
            action: @escaping (OnboardingIntroViewModel.DuckAIExperimentSelection) -> Void,
            openAIChatAction: @escaping (String?, Bool) -> Void,
            openSearchAction: @escaping (String) -> Void,
            measureQuerySubmissionAction: @escaping (Bool, DuckAIQueryExperimentPromptSource) -> Void,
            startExitTransitionAction: @escaping () -> Void
        ) {
            self.action = action
            self.openAIChatAction = openAIChatAction
            self.openSearchAction = openSearchAction
            self.measureQuerySubmissionAction = measureQuerySubmissionAction
            self.startExitTransitionAction = startExitTransitionAction
            self.visualStyle = visualStyle
            self.shouldAnimateToDuckAIOnAppear = defaultExperience == .duckAI
            let startsInSearchMode = defaultExperience == .search || shouldAnimateToDuckAIOnAppear
            let initialSelection = startsInSearchMode ? Self.pickerItems[0] : Self.pickerItems[1]
            _isDuckAISelected = State(initialValue: !startsInSearchMode)
            _pickerViewModel = StateObject(wrappedValue: ImageSegmentedPickerViewModel(
                items: Self.pickerItems,
                selectedItem: initialSelection,
                configuration: ImageSegmentedPickerConfiguration(itemContentSpacing: Metrics.queryFieldContentSpacing),
                scrollProgress: startsInSearchMode ? 0 : 1,
                isScrollProgressDriven: false
            ))
        }

        // MARK: View
        var body: some View {
            VStack(spacing: Metrics.contentVerticalSpacing) {
                // Header text inside the onboarding bubble.
                Text(UserText.Onboarding.DuckAIQueryExperiment.title)
                    .font(visualStyle == .rebranded ? onboardingTheme.typography.title : Font(UIFont.daxTitle3()))
                    .multilineTextAlignment(visualStyle == .rebranded ? .center : .leading)
                    .foregroundColor(visualStyle == .rebranded ? onboardingTheme.colorPalette.textPrimary : Color(designSystemColor: .textPrimary))
                    .frame(maxWidth: .infinity, alignment: visualStyle == .rebranded ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Search / Duck.ai segmented control.
                ImageSegmentedPickerView(viewModel: pickerViewModel)
                    .frame(width: Metrics.pickerWidth, height: Metrics.pickerHeight)
                    .padding(.vertical, Metrics.pickerVerticalPadding)
                    .frame(width: Metrics.pickerWidth, height: Metrics.pickerContainerHeight)
                    // Drive content mode (Search vs Duck.ai) from user picker selection.
                    .onChange(of: pickerViewModel.selectedItem) { selectedItem in
                        SwiftUI.withAnimation(.easeInOut(duration: Metrics.pickerSelectionAnimationDuration)) {
                            isDuckAISelected = selectedItem == Self.pickerItems[1]
                        }
                    }
                    // Keep picker model + visual progress in sync for programmatic/default mode changes.
                    .onChange(of: isDuckAISelected) { isSelected in
                        let selection = isSelected ? Self.pickerItems[1] : Self.pickerItems[0]
                        if pickerViewModel.selectedItem != selection {
                            pickerViewModel.selectItem(selection)
                        }
                        pickerViewModel.updateScrollProgress(isSelected ? 1 : 0)
                        // During initial intro animation, delay focus until animation completion.
                        if !isRunningInitialSelectionAnimation {
                            requestInputFocus()
                        }
                    }
                    .padding(.top, titleToPickerTopPadding)
                    .padding(.bottom, Metrics.pickerBottomPadding)

                // Query field + trailing action icon.
                queryField
                    .padding(.top, Metrics.queryFieldTopPadding)
                    .padding(.bottom, Metrics.queryFieldBottomPadding)

                // Delayed/staggered suggestion chips.
                if visibleSuggestionCount > 0 {
                    suggestionChips
                        .padding(.top, Metrics.fieldToFirstChipTopPadding)
                }
            }
            .opacity(isTransitioningOut ? 0 : 1)
            .onAppear {
                isInputFocused = false
                hasPassedInitialFocusDelay = false
                shouldFocusWhenInitialDelayPasses = false
                suggestionSequenceStarted = false
                scheduleInitialFocusGate()
                startInitialSelectionAnimationIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                startSuggestionSequenceIfNeeded()
            }
            // Fade out this content while transitioning to the selected destination.
            .animation(.easeInOut(duration: Metrics.contentFadeAnimationDuration), value: isTransitioningOut)
        }

        // MARK: Style
        private var accentColor: Color {
            visualStyle == .rebranded ? Color(singleUseColor: .rebranding(.accentPrimary)) : Color(designSystemColor: .accent)
        }

        private var titleToPickerTopPadding: CGFloat {
            visualStyle == .rebranded ? Metrics.rebrandedTitleToPickerTopPadding : Metrics.legacyTitleToPickerTopPadding
        }

        private var accentSecondaryColor: Color {
            visualStyle == .rebranded ? Color(singleUseColor: .rebranding(.accentAltGlowPrimary)) : Color(designSystemColor: .accentGlowSecondary)
        }

        private var queryFieldBackgroundColor: Color {
            visualStyle == .rebranded ? onboardingTheme.colorPalette.background : Color(designSystemColor: .surface)
        }

        private var queryFieldBorderWidth: CGFloat {
            visualStyle == .rebranded ? Metrics.rebrandedQueryFieldBorderWidth : Metrics.legacyQueryFieldBorderWidth
        }

        private var suggestionChipBorderWidth: CGFloat {
            visualStyle == .rebranded ? Metrics.rebrandedSuggestionChipBorderWidth : Metrics.legacySuggestionChipBorderWidth
        }

        private var initialInputFocusDelayAfterAppear: TimeInterval {
            visualStyle == .rebranded ? Metrics.rebrandedInitialInputFocusDelayAfterAppear : Metrics.legacyInitialInputFocusDelayAfterAppear
        }

        // MARK: Initial Sequencing
        private func startInitialSelectionAnimationIfNeeded() {
            if !didRunInitialToggleAnimation {
                didRunInitialToggleAnimation = true
                if shouldAnimateToDuckAIOnAppear {
                    // Treatment A behavior: start in Search, then animate to Duck.ai.
                    isDuckAISelected = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.initialToggleStartDelay) {
                        guard didRunInitialToggleAnimation else { return }
                        isRunningInitialSelectionAnimation = true
                        withAnimation(.easeInOut(duration: Metrics.pickerSelectionAnimationDuration)) {
                            isDuckAISelected = true
                        } completion: {
                            isRunningInitialSelectionAnimation = false
                            requestInputFocus()
                            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.suggestionRevealFallbackDelayAfterFocus) {
                                startSuggestionSequenceIfNeeded()
                            }
                        }
                    }
                } else {
                    // Treatment B behavior: stay in Search, no auto-switch.
                    isDuckAISelected = false
                    requestInputFocus()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.suggestionRevealFallbackDelayAfterFocus) {
                        startSuggestionSequenceIfNeeded()
                    }
                }
            }
        }

        private func scheduleInitialFocusGate() {
            DispatchQueue.main.asyncAfter(deadline: .now() + initialInputFocusDelayAfterAppear) {
                hasPassedInitialFocusDelay = true
                if shouldFocusWhenInitialDelayPasses {
                    shouldFocusWhenInitialDelayPasses = false
                    isInputFocused = true
                }
            }
        }

        private func requestInputFocus() {
            if hasPassedInitialFocusDelay {
                isInputFocused = true
            } else {
                shouldFocusWhenInitialDelayPasses = true
            }
        }

        // MARK: Subviews
        private var queryField: some View {
            HStack(alignment: .bottom, spacing: Metrics.queryFieldContentSpacing) {
                // Text input
                OnboardingQueryField(
                    text: $query,
                    placeholder: isDuckAISelected
                    ? UserText.Onboarding.DuckAIQueryExperiment.aiPlaceholder
                    : UserText.Onboarding.DuckAIQueryExperiment.searchPlaceholder,
                    isFocused: $isInputFocused,
                    isSingleLine: !isDuckAISelected,
                    onSubmit: handlePrimaryAction
                )
                .transaction { transaction in
                    // Prevent placeholder/baseline shifts from inheriting parent animations when toggling mode.
                    transaction.animation = nil
                }
                .frame(
                    height: isDuckAISelected ? Metrics.multilineFieldHeight : Metrics.singleLineFieldHeight,
                    alignment: isDuckAISelected ? .topLeading : .center
                )

                // Submit action button
                Button(action: handlePrimaryAction) {
                    Image(
                        uiImage: isDuckAISelected
                        ? DesignSystemImages.Glyphs.Size16.arrowRight
                        : DesignSystemImages.Glyphs.Size24.findSearchSmall
                    )
                    .renderingMode(.template)
                    .font(Font(UIFont.daxBodyBold()))
                    .foregroundColor(visualStyle == .rebranded ? accentColor : Color(designSystemColor: .icons))
                    .opacity(isPrimaryActionEnabled ? 1 : Metrics.disabledPrimaryActionOpacity)
                    .frame(width: Metrics.queryFieldActionButtonSize, height: Metrics.queryFieldActionButtonSize)
                    .offset(x: Metrics.queryFieldActionOffsetX, y: Metrics.queryFieldActionOffsetY)
                }
                .buttonStyle(.plain)
                .disabled(!isPrimaryActionEnabled)
            }
            .padding(.horizontal, Metrics.queryFieldHorizontalPadding)
            .padding(.vertical, Metrics.queryFieldVerticalPadding)
            .background(queryFieldBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.queryFieldCornerRadius)
                    .strokeBorder(accentSecondaryColor, lineWidth: queryFieldBorderWidth)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.queryFieldCornerRadius)
                    .inset(by: Metrics.queryFieldInnerBorderInset)
                    .strokeBorder(accentColor, lineWidth: queryFieldBorderWidth)
            )
            .cornerRadius(Metrics.queryFieldCornerRadius)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: Metrics.contentFadeAnimationDuration), value: isDuckAISelected)
        }

        private var suggestionChips: some View {
            VStack(spacing: Metrics.interChipSpacing) {
                if visibleSuggestionCount >= 1 {
                    suggestionChip(
                        isDuckAISelected
                        ? UserText.Onboarding.DuckAIQueryExperiment.suggestionOption1
                        : UserText.Onboarding.DuckAIQueryExperiment.searchSuggestionOption1,
                        promptSource: .option1,
                        icon: suggestionIcon
                    )
                    .transition(suggestionTransition)
                }
                if visibleSuggestionCount >= 2 {
                    suggestionChip(
                        isDuckAISelected
                        ? UserText.Onboarding.DuckAIQueryExperiment.suggestionOption2
                        : UserText.Onboarding.DuckAIQueryExperiment.searchSuggestionOption2,
                        promptSource: .option2,
                        icon: suggestionIcon
                    )
                    .transition(suggestionTransition)
                }
                if visibleSuggestionCount >= 3 {
                    suggestionChip(
                        UserText.Onboarding.DuckAIQueryExperiment.suggestionSurpriseMe,
                        promptSource: .option3,
                        icon: DesignSystemImages.Glyphs.Size16.wand
                    )
                    .transition(suggestionTransition)
                }
            }
        }

        private var suggestionIcon: UIImage {
            isDuckAISelected ? DesignSystemImages.Glyphs.Size16.aiChat : DesignSystemImages.Glyphs.Size24.findSearchSmall
        }

        private var suggestionTransition: AnyTransition {
            .asymmetric(
                insertion: .scale(scale: Metrics.suggestionTransitionScale, anchor: .top).combined(with: .opacity),
                removal: .opacity
            )
        }

        private var suggestionChipHeight: CGFloat {
            visualStyle == .rebranded ? Metrics.rebrandedChipHeight : Metrics.legacyChipHeight
        }

        private var suggestionChipCornerRadius: CGFloat {
            visualStyle == .rebranded ? Metrics.rebrandedChipCornerRadius : Metrics.legacyChipCornerRadius
        }

        private var suggestionAppearanceAnimation: Animation {
            .interpolatingSpring(
                mass: Metrics.suggestionSpringMass,
                stiffness: Metrics.suggestionSpringStiffness,
                damping: Metrics.suggestionSpringDamping,
                initialVelocity: Metrics.suggestionSpringInitialVelocity
            )
        }

        private func suggestionChip(_ title: String, promptSource: DuckAIQueryExperimentPromptSource, icon: UIImage) -> some View {
            Button {
                openSelectedExperience(prompt: title, autoSend: true, promptSource: promptSource)
            } label: {
                HStack(spacing: Metrics.suggestionChipContentSpacing) {
                    Image(uiImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Metrics.suggestionChipIconSize, height: Metrics.suggestionChipIconSize)
                    Text(title)
                        .font(Font(UIFont.daxBodyBold()))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundColor(accentColor)
                .padding(.leading, Metrics.suggestionChipLeadingPadding)
                .padding(.trailing, Metrics.suggestionChipTrailingPadding)
                .frame(maxWidth: .infinity)
                .frame(height: suggestionChipHeight)
                // Make the whole button area tappable, when there's no background.
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: suggestionChipCornerRadius)
                        .strokeBorder(accentColor, lineWidth: suggestionChipBorderWidth)
                )
            }
            .buttonStyle(OutlinedSuggestionChipButtonStyle(cornerRadius: suggestionChipCornerRadius))
        }

        // MARK: Actions
        private func handlePrimaryAction() {
            guard isPrimaryActionEnabled else { return }
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            openSelectedExperience(
                prompt: trimmedQuery.isEmpty ? nil : trimmedQuery,
                autoSend: !trimmedQuery.isEmpty,
                promptSource: .custom
            )
        }

        private var isPrimaryActionEnabled: Bool {
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private func openSelectedExperience(prompt: String?, autoSend: Bool, promptSource: DuckAIQueryExperimentPromptSource) {
            if autoSend {
                measureQuerySubmissionAction(isDuckAISelected, promptSource)
            }

            let preloadedSearchQuery: String? = {
                guard !isDuckAISelected, let searchQuery = prompt, !searchQuery.isEmpty else { return nil }
                return searchQuery
            }()

            // Start browser loading immediately so results can be ready behind the exit hold.
            if let searchQuery = preloadedSearchQuery {
                openSearchAction(searchQuery)
            }

            isInputFocused = false
            dismissKeyboard()
            startExitTransitionAction()

            withAnimation(.easeOut(duration: Metrics.contentFadeAnimationDuration)) {
                isTransitioningOut = true
            } completion: {
                if isDuckAISelected {
                    openAIChatAction(prompt, autoSend)
                    action(.searchAndDuckAI)
                } else if preloadedSearchQuery != nil {
                    action(.searchOnly)
                } else {
                    isTransitioningOut = false
                }
            }
        }

        // MARK: Suggestion Sequencing
        private func startSuggestionSequenceIfNeeded() {
            guard !suggestionSequenceStarted else { return }
            suggestionSequenceStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.suggestionInitialRevealDelay) {
                guard suggestionSequenceStarted, !isTransitioningOut else { return }
                startSuggestionRevealSequence()
            }
        }

        private func startSuggestionRevealSequence() {
            guard suggestionSequenceStarted, !isTransitioningOut else { return }
            visibleSuggestionCount = 0
            revealSuggestionsSequentially(nextIndex: 1)
        }

        private func revealSuggestionsSequentially(nextIndex: Int) {
            guard suggestionSequenceStarted, !isTransitioningOut else { return }
            guard nextIndex <= Metrics.maxSuggestionCount else { return }

            withAnimation(suggestionAppearanceAnimation) {
                visibleSuggestionCount = nextIndex
            } completion: {
                revealSuggestionsSequentially(nextIndex: nextIndex + 1)
            }
        }

        // MARK: Utilities
        @MainActor
        private func withAnimation(_ animation: Animation, _ updates: @escaping () -> Void, completion: @escaping () -> Void) {
            if #available(iOS 17, *) {
                SwiftUI.withAnimation(animation, completionCriteria: .logicallyComplete, updates) {
                    completion()
                }
            } else {
                CATransaction.begin()
                CATransaction.setCompletionBlock(completion)
                SwiftUI.withAnimation(animation, updates)
                CATransaction.commit()
            }
        }

        private func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

}
// MARK: - OnboardingQueryField
private struct OnboardingQueryField: UIViewRepresentable {
    private static let singleLineTopInset: CGFloat = 5.0 / 3.0
    private static let multiLineTopInset: CGFloat = 10.0 / 3.0

    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let isSingleLine: Bool
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()

        textView.backgroundColor = .clear
        textView.font = .daxBodyRegular()
        textView.textColor = UIColor(designSystemColor: .textPrimary)

        textView.delegate = context.coordinator

        textView.isScrollEnabled = true
        textView.showsHorizontalScrollIndicator = false
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = false

        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyModeConfiguration(to: textView, isSingleLine: isSingleLine, context: context)

        context.coordinator.placeholderLabel.text = placeholder
        context.coordinator.placeholderLabel.font = textView.font
        context.coordinator.placeholderLabel.textColor = UIColor(designSystemColor: .textTertiary)
        context.coordinator.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.addSubview(context.coordinator.placeholderLabel)

        let placeholderTopConstraint = context.coordinator.placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor)
        context.coordinator.placeholderTopConstraint = placeholderTopConstraint

        NSLayoutConstraint.activate([
            context.coordinator.placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderTopConstraint
        ])

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }

        if context.coordinator.isSingleLine != isSingleLine {
            context.coordinator.isSingleLine = isSingleLine
            applyModeConfiguration(to: textView, isSingleLine: isSingleLine, context: context)
        }

        let topInset = isSingleLine ? Self.singleLineTopInset : Self.multiLineTopInset

        UIView.performWithoutAnimation {
            textView.textContainerInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            context.coordinator.placeholderTopConstraint?.constant = topInset
            textView.layoutIfNeeded()
        }

        if isFocused {
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
        } else if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    private func applyModeConfiguration(to textView: UITextView, isSingleLine: Bool, context: Context) {
        textView.returnKeyType = isSingleLine ? .search : .go
        textView.alwaysBounceHorizontal = isSingleLine

        if isSingleLine {
            textView.textContainer.widthTracksTextView = false
            textView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 34)
            textView.textContainer.maximumNumberOfLines = 1
            textView.textContainer.lineBreakMode = .byClipping
        } else {
            textView.textContainer.widthTracksTextView = true
            textView.textContainer.size = CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.lineBreakMode = .byWordWrapping
        }
        let savedSelection = textView.selectedRange
        textView.selectedRange = NSRange(location: 0, length: 0)
        DispatchQueue.main.async {
            context.coordinator.adjustContentSizeIfNeeded(textView)
            textView.selectedRange = savedSelection
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            isSingleLine: isSingleLine,
            onSubmit: onSubmit
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool

        var isSingleLine: Bool
        private let onSubmit: () -> Void

        let placeholderLabel = UILabel()
        var placeholderTopConstraint: NSLayoutConstraint?

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            isSingleLine: Bool,
            onSubmit: @escaping () -> Void
        ) {
            _text = text
            _isFocused = isFocused
            self.isSingleLine = isSingleLine
            self.onSubmit = onSubmit
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text ?? ""
            placeholderLabel.isHidden = !text.isEmpty
            adjustContentSizeIfNeeded(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if isFocused {
                DispatchQueue.main.async {
                    textView.becomeFirstResponder()
                }
            } else {
                isFocused = false
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            if replacement == "\n" {
                onSubmit()
                return false
            }

            guard isSingleLine else { return true }

            // Sanitize single-line text input to prevent line breaks.
            if replacement.contains("\n"),
               let currentText = textView.text,
               let swiftRange = Range(range, in: currentText) {

                let normalized = replacement.replacingOccurrences(of: "\n", with: " ")
                let updated = currentText.replacingCharacters(in: swiftRange, with: normalized)

                textView.text = updated
                textView.selectedRange = NSRange(location: range.location + normalized.count, length: 0)

                text = updated
                placeholderLabel.isHidden = !updated.isEmpty
                return false
            }

            return true
        }

        func adjustContentSizeIfNeeded(_ textView: UITextView) {
            guard isSingleLine, let font = textView.font else { return }

            let padding: CGFloat = 12

            let textWidth = (textView.text as NSString).size(withAttributes: [.font: font]).width + padding * 2
            textView.contentSize = CGSize(width: textWidth, height: textView.bounds.height)
        }

    }
}

// MARK: - OutlinedSuggestionChipButtonStyle
private struct OutlinedSuggestionChipButtonStyle: ButtonStyle {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 12) {
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(designSystemColor: .accent).opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
