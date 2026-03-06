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

import SwiftUI
import UIKit
import QuartzCore
import DesignResourcesKit
import DesignResourcesKitIcons
import DuckUI
import UIComponents

extension OnboardingView {
    private enum Metrics {
        static let initialToggleStartDelay: TimeInterval = 0.35
        static let suggestionInitialRevealDelay: TimeInterval = 4
        static let suggestionRevealFallbackDelayAfterFocus: TimeInterval = 0.4
        static let pickerSelectionAnimationDuration: TimeInterval = 0.22
        static let contentFadeAnimationDuration: TimeInterval = 0.2
        static let pickerContainerHeight: CGFloat = 124.0 / 3.0
        static let singleLineFieldHeight: CGFloat = 26
        static let multilineFieldHeight: CGFloat = 56
    }

    struct DuckAIExperimentSearchContent: View {
        private let action: (OnboardingIntroViewModel.DuckAIExperimentSelection) -> Void
        private let openAIChatAction: (String?, Bool) -> Void
        private let openSearchAction: (String) -> Void
        private let measureQuerySubmissionAction: (Bool, DuckAIQueryExperimentPromptSource) -> Void
        private let startExitTransitionAction: (Bool) -> Void
        @StateObject private var pickerViewModel: ImageSegmentedPickerViewModel

        @State private var query = ""
        @State private var isDuckAISelected: Bool
        @State private var isInputFocused = false
        @State private var visibleSuggestionCount = 0
        @State private var didRunInitialToggleAnimation = false
        @State private var isTransitioningOut = false
        @State private var isRunningInitialSelectionAnimation = false
        @State private var suggestionSequenceStarted = false
        private let defaultDuckAISelection: Bool

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
            defaultSelection: Bool,
            action: @escaping (OnboardingIntroViewModel.DuckAIExperimentSelection) -> Void,
            openAIChatAction: @escaping (String?, Bool) -> Void,
            openSearchAction: @escaping (String) -> Void,
            measureQuerySubmissionAction: @escaping (Bool, DuckAIQueryExperimentPromptSource) -> Void,
            startExitTransitionAction: @escaping (Bool) -> Void
        ) {
            self.action = action
            self.openAIChatAction = openAIChatAction
            self.openSearchAction = openSearchAction
            self.measureQuerySubmissionAction = measureQuerySubmissionAction
            self.startExitTransitionAction = startExitTransitionAction
            self.defaultDuckAISelection = defaultSelection
            let initialSelection = defaultSelection ? Self.pickerItems[0] : Self.pickerItems[1]
            _isDuckAISelected = State(initialValue: !defaultSelection)
            _pickerViewModel = StateObject(wrappedValue: ImageSegmentedPickerViewModel(
                items: Self.pickerItems,
                selectedItem: initialSelection,
                configuration: ImageSegmentedPickerConfiguration(itemContentSpacing: 8),
                scrollProgress: defaultSelection ? 0 : 1,
                isScrollProgressDriven: false
            ))
        }

        var body: some View {
            VStack(spacing: 16) {
                // Header text inside the onboarding bubble.
                Text(UserText.Onboarding.DuckAIQueryExperiment.title)
                    .font(Font(UIFont.daxTitle3()))
                    .multilineTextAlignment(.leading)
                    .foregroundColor(Color(designSystemColor: .textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Search / Duck.ai segmented control.
                ImageSegmentedPickerView(viewModel: pickerViewModel)
                    .frame(width: 216, height: 38)
                    .padding(.vertical, 0.5)
                    .frame(width: 216, height: Metrics.pickerContainerHeight)
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
                            isInputFocused = true
                        }
                    }
                    .padding(.top, 7.33)
                    .padding(.bottom, 3.67)

                // Query field + trailing action icon.
                queryField
                    .padding(.top, -12)
                    .padding(.bottom, -7.67)

                // Delayed/staggered suggestion chips.
                if visibleSuggestionCount > 0 {
                    suggestionChips
                }
            }
            .opacity(isTransitioningOut ? 0 : 1)
            .onAppear {
                isInputFocused = false
                suggestionSequenceStarted = false
                startInitialSelectionAnimationIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                startSuggestionSequenceIfNeeded()
            }
            // Fade out this content while transitioning to the selected destination.
            .animation(.easeInOut(duration: Metrics.contentFadeAnimationDuration), value: isTransitioningOut)
        }

        private func startInitialSelectionAnimationIfNeeded() {
            if !didRunInitialToggleAnimation {
                didRunInitialToggleAnimation = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.initialToggleStartDelay) {
                    guard didRunInitialToggleAnimation else { return }
                    // Short intro animation: move from initial picker state to experiment default.
                    // Start keyboard focus together with toggle animation for near-simultaneous motion.
                    isRunningInitialSelectionAnimation = true
                    isInputFocused = true
                    withAnimation(.easeInOut(duration: Metrics.pickerSelectionAnimationDuration)) {
                        isDuckAISelected = defaultDuckAISelection
                    } completion: {
                        isRunningInitialSelectionAnimation = false
                        // Fallback for hardware keyboard / no keyboard animation callback.
                        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.suggestionRevealFallbackDelayAfterFocus) {
                            startSuggestionSequenceIfNeeded()
                        }
                    }
                }
            }
        }

        private var queryField: some View {
            HStack(alignment: .bottom, spacing: 8) {
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
                .frame(height: isDuckAISelected ? 56 : 26, alignment: isDuckAISelected ? .topLeading : .center)

                // Submit action button
                Button(action: handlePrimaryAction) {
                    Image(
                        uiImage: isDuckAISelected
                        ? DesignSystemImages.Glyphs.Size16.arrowRight
                        : DesignSystemImages.Glyphs.Size24.findSearchSmall
                    )
                    .renderingMode(.template)
                    .font(Font(UIFont.daxBodyBold()))
                    .foregroundColor(Color(designSystemColor: .icons))
                    .opacity(isPrimaryActionEnabled ? 1 : 0.3)
                    .frame(width: 28, height: 28)
                    .offset(x: 2.33, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(!isPrimaryActionEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16.33)
            .background(Color(designSystemColor: .surface))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(designSystemColor: .accentGlowSecondary), lineWidth: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .inset(by: 2)
                    .strokeBorder(Color(designSystemColor: .accent), lineWidth: 2)
            )
            .cornerRadius(14)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: Metrics.contentFadeAnimationDuration), value: isDuckAISelected)
        }

        private var suggestionChips: some View {
            VStack(spacing: 9.33) {
                if visibleSuggestionCount >= 1 {
                    suggestionChip(
                        UserText.Onboarding.DuckAIQueryExperiment.suggestionOption1,
                        promptSource: .option1,
                        icon: DesignSystemImages.Glyphs.Size16.aiChat
                    )
                    .transition(suggestionTransition)
                }
                if visibleSuggestionCount >= 2 {
                    suggestionChip(
                        UserText.Onboarding.DuckAIQueryExperiment.suggestionOption2,
                        promptSource: .option2,
                        icon: DesignSystemImages.Glyphs.Size16.aiChat
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

        private var suggestionTransition: AnyTransition {
            .asymmetric(
                insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                removal: .opacity
            )
        }

        private var suggestionAppearanceAnimation: Animation {
            .interpolatingSpring(mass: 0.7, stiffness: 180, damping: 14, initialVelocity: 0.25)
        }

        private func suggestionChip(_ title: String, promptSource: DuckAIQueryExperimentPromptSource, icon: UIImage) -> some View {
            Button {
                openSelectedExperience(prompt: title, autoSend: true, promptSource: promptSource)
            } label: {
                HStack(spacing: 8) {
                    Image(uiImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text(title)
                        .font(Font(UIFont.daxBodyBold()))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundColor(Color(designSystemColor: .accent))
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 46.33)
                // Make the whole button area tappable, when there's no background.
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(designSystemColor: .accent), lineWidth: 1)
                )
            }
            .buttonStyle(OutlinedSuggestionChipButtonStyle())
        }

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

            isInputFocused = false
            dismissKeyboard()
            startExitTransitionAction(isDuckAISelected)

            withAnimation(.easeOut(duration: Metrics.contentFadeAnimationDuration)) {
                isTransitioningOut = true
            } completion: {
                if isDuckAISelected {
                    openAIChatAction(prompt, autoSend)
                    action(.searchAndDuckAI)
                } else if let searchQuery = prompt, !searchQuery.isEmpty {
                    openSearchAction(searchQuery)
                    action(.searchOnly)
                } else {
                    isTransitioningOut = false
                }
            }
        }

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
            guard nextIndex <= 3 else { return }

            withAnimation(suggestionAppearanceAnimation) {
                visibleSuggestionCount = nextIndex
            } completion: {
                revealSuggestionsSequentially(nextIndex: nextIndex + 1)
            }
        }

        @MainActor
        private func withAnimation(_ animation: Animation, _ updates: @escaping () -> Void, completion: @escaping () -> Void) {
#if os(iOS)
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
#else
            SwiftUI.withAnimation(animation, updates)
            completion()
#endif
        }

        private func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

}

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

private struct OutlinedSuggestionChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(designSystemColor: .accent).opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
