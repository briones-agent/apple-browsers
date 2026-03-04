//
//  OnboardingView.swift
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
import Onboarding
import DuckUI
import SystemSettingsPiPTutorial
import MetricBuilder
import UIKit
import DesignResourcesKit
import DesignResourcesKitIcons
import Core
import AIChat
import UIComponents

// MARK: - OnboardingView

struct OnboardingView: View {

    static let daxGeometryEffectID = "DaxIcon"

    @Namespace var animationNamespace
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var model: OnboardingIntroViewModel
    @State private var showExperimentExitOverlay = false
    @State private var experimentExitToDuckAI = false
    @State private var experimentExitOverlayOpacity: CGFloat = 0
    @State private var experimentChromeVisible = false
    @State private var isExperimentDialogFadingOut = false

    init(model: OnboardingIntroViewModel) {
        self.model = model
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            OnboardingBackground()

            switch model.state {
            case .landing:
                landingView
            case let .onboarding(viewState):
                onboardingDialogView(state: viewState)
#if DEBUG || ALPHA
                    .safeAreaInset(edge: .bottom) {
                        Button {
                            model.overrideOnboardingCompleted()
                        } label: {
                            Text(UserText.Onboarding.Intro.Debug.skip)
                        }
                        .buttonStyle(SecondaryFillButtonStyle(compact: true, fullWidth: false))
                    }
#endif
            }

            if showExperimentExitOverlay {
                experimentExitOverlay
                    .transition(.opacity)
            }
        }
    }

    private func onboardingDialogView(state: ViewState.Intro) -> some View {
        GeometryReader { geometry in
            let verticalOffset = state.type.isExperimentSearchScreen
            ? Metrics.experimentDialogTopOffset
            : geometry.size.height * Metrics.dialogVerticalOffsetPercentage.build(v: verticalSizeClass, h: horizontalSizeClass)
            let contentInsets: EdgeInsets = state.type.isExperimentSearchScreen
            ? .init(top: 24, leading: 24, bottom: 10, trailing: 24)
            : .init(top: 24, leading: 24, bottom: 24, trailing: 24)

            VStack(alignment: .center) {
                DaxDialogView(
                    logoPosition: .top,
                    matchLogoAnimation: (Self.daxGeometryEffectID, animationNamespace),
                    showDialogBox: $model.introState.showDaxDialogBox,
                    showLogo: !state.type.isExperimentSearchScreen,
                    showBubbleArrow: !state.type.isExperimentSearchScreen,
                    contentInsets: contentInsets,
                    onTapGesture: {
                        withAnimation {
                            model.tapped()
                        }
                    },
                    content: {
                        VStack {
                            switch state.type {
                            case .startOnboardingDialog(let shouldShowSkipOnboardingButton):
                                introView(shouldShowSkipOnboardingButton: shouldShowSkipOnboardingButton)
                            case .browsersComparisonDialog:
                                browsersComparisonView
                            case .addToDockPromoDialog:
                                addToDockPromoView
                            case .chooseAppIconDialog:
                                appIconPickerView
                            case .chooseAddressBarPositionDialog:
                                addressBarPreferenceSelectionView
                            case .chooseSearchExperienceDialog:
                                searchExperienceSelectionView
                            case .duckAIQueryExperimentDialog(let defaultSelection):
                                experimentSearchExperienceSelectionView(defaultSelection: defaultSelection)
                            }
                        }
                    }
                )
                .onboardingProgressIndicator(
                    currentStep: state.step.currentStep,
                    totalSteps: state.step.totalSteps,
                    isVisible: !state.type.isExperimentSearchScreen
                )
            }
            .opacity(isExperimentDialogFadingOut && state.type.isExperimentSearchScreen ? 0 : 1)
            .frame(width: geometry.size.width, alignment: .center)
            .offset(y: verticalOffset)
            .onAppear {
                if state.type.isExperimentSearchScreen {
                    resetExperimentExitTransition()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.daxDialogVisibilityDelay) {
                    model.introState.showDaxDialogBox = true
                    model.introState.animateIntroText = true
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: state.type)
        }
        .padding(16)
    }

    private var landingView: some View {
        return LandingView(animationNamespace: animationNamespace)
            .ignoresSafeArea(edges: .bottom)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.daxDialogDelay) {
                    withAnimation {
                        model.onAppear()
                    }
                }
            }
    }

    private func introView(shouldShowSkipOnboardingButton: Bool) -> some View {
        let skipOnboardingView: AnyView? = if shouldShowSkipOnboardingButton {
            AnyView(
                SkipOnboardingContent(
                    animateTitle: $model.skipOnboardingState.animateTitle,
                    animateMessage: $model.skipOnboardingState.animateMessage,
                    showCTA: $model.skipOnboardingState.showContent,
                    isSkipped: $model.isSkipped,
                    startBrowsingAction: model.confirmSkipOnboardingAction,
                    resumeOnboardingAction: {
                        animateBrowserComparisonViewState(isResumingOnboarding: true)
                    }
                )
            )
        } else {
            nil
        }

        return IntroDialogContent(
            title: model.copy.introTitle,
            skipOnboardingView: skipOnboardingView,
            animateText: $model.introState.animateIntroText,
            showCTA: $model.introState.showIntroButton,
            isSkipped: $model.isSkipped,
            continueAction: {
                animateBrowserComparisonViewState(isResumingOnboarding: false)
            },
            skipAction: model.skipOnboardingAction
        )
        .onboardingDaxDialogStyle()
        .visibility(model.introState.showIntroViewContent ? .visible : .invisible)
    }

    private var browsersComparisonView: some View {
        BrowsersComparisonContent(
            title: model.copy.browserComparisonTitle,
            animateText: $model.browserComparisonState.animateComparisonText,
            showContent: $model.browserComparisonState.showComparisonButton,
            isSkipped: $model.isSkipped,
            setAsDefaultBrowserAction: model.setDefaultBrowserAction,
            cancelAction: model.cancelSetDefaultBrowserAction
        )
        .onboardingDaxDialogStyle()
    }

    private var addToDockPromoView: some View {
        AddToDockPromoContent(
            isAnimating: $model.addToDockState.isAnimating,
            isSkipped: $model.isSkipped,
            showTutorialAction: {
                model.addToDockShowTutorialAction()
            },
            dismissAction: { fromAddToDockTutorial in
                model.addToDockContinueAction(isShowingAddToDockTutorial: fromAddToDockTutorial)
            }
        )
    }

    private var appIconPickerView: some View {
        AppIconPickerContent(
            animateTitle: $model.appIconPickerContentState.animateTitle,
            animateMessage: $model.appIconPickerContentState.animateMessage,
            showContent: $model.appIconPickerContentState.showContent,
            isSkipped: $model.isSkipped,
            action: model.appIconPickerContinueAction
        )
        .onboardingDaxDialogStyle()
    }

    private var addressBarPreferenceSelectionView: some View {
        AddressBarPositionContent(
            animateTitle: $model.addressBarPositionContentState.animateTitle,
            showContent: $model.addressBarPositionContentState.showContent,
            isSkipped: $model.isSkipped,
            action: model.selectAddressBarPositionAction
        )
        .onboardingDaxDialogStyle()
    }

    private var searchExperienceSelectionView: some View {
        SearchExperienceContent(
            animateTitle: $model.searchExperienceContentState.animateTitle,
            isSkipped: $model.isSkipped,
            action: model.selectSearchExperienceAction
        )
        .onboardingDaxDialogStyle()
    }

    private func experimentSearchExperienceSelectionView(defaultSelection: Bool) -> some View {
        DuckAIExperimentSearchContent(
            defaultSelection: defaultSelection,
            action: model.selectDuckAIQueryExperimentAction,
            openAIChatAction: model.openAIChatFromOnboarding,
            openSearchAction: model.searchFromOnboarding,
            measureQuerySubmissionAction: model.measureDuckAIQueryExperimentQuerySubmission,
            startExitTransitionAction: { isDuckAISelected in
                beginExperimentExitTransition(isDuckAISelected: isDuckAISelected)
            }
        )
        .onboardingDaxDialogStyle()
    }

    private var experimentExitOverlay: some View {
        GeometryReader { geometry in
            ZStack {
                let backgroundColor = experimentExitToDuckAI
                ? Color(designSystemColor: .surface)
                : Color(uiColor: .systemBackground)

                backgroundColor
                    .opacity(experimentExitOverlayOpacity)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Color(uiColor: .secondarySystemBackground)
                        .frame(height: Metrics.chromeTopHeight)
                        .offset(y: experimentChromeVisible ? 0 : -Metrics.chromeTopHeight)
                    Spacer()
                    Color(uiColor: .secondarySystemBackground)
                        .frame(height: Metrics.chromeBottomHeight)
                        .offset(y: experimentChromeVisible ? 0 : Metrics.chromeBottomHeight)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
    }

    private func beginExperimentExitTransition(isDuckAISelected: Bool) {
        experimentExitToDuckAI = isDuckAISelected
        showExperimentExitOverlay = true
        withAnimation(.easeInOut(duration: 0.18)) {
            isExperimentDialogFadingOut = true
            experimentExitOverlayOpacity = 1
        }
        withAnimation(.interpolatingSpring(mass: 0.7, stiffness: 180, damping: 18, initialVelocity: 0.15).delay(0.05)) {
            experimentChromeVisible = true
        }
    }

    private func resetExperimentExitTransition() {
        showExperimentExitOverlay = false
        experimentExitToDuckAI = false
        experimentExitOverlayOpacity = 0
        experimentChromeVisible = false
        isExperimentDialogFadingOut = false
    }

    private func animateBrowserComparisonViewState(isResumingOnboarding: Bool) {
        // Hide content of Intro dialog before animating
        model.introState.showIntroViewContent = false

        // Animation with small delay for a better effect when intro content disappear
        let animationDuration = Metrics.comparisonChartAnimationDuration
        let animation = Animation
            .linear(duration: animationDuration)
            .delay(0.2)

        if #available(iOS 17, *) {
            withAnimation(animation) {
                model.startOnboardingAction(isResumingOnboarding: isResumingOnboarding)
            } completion: {
                model.browserComparisonState.animateComparisonText = true
            }
        } else {
            withAnimation(animation) {
                model.startOnboardingAction(isResumingOnboarding: isResumingOnboarding)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                model.browserComparisonState.animateComparisonText = true
            }
        }
    }

    struct DuckAIExperimentSearchContent: View {
        private let action: () -> Void
        private let openAIChatAction: (String?, Bool) -> Void
        private let openSearchAction: (String) -> Void
        private let measureQuerySubmissionAction: (Bool, DuckAIQueryExperimentPromptSource) -> Void
        private let startExitTransitionAction: (Bool) -> Void
        @StateObject private var pickerViewModel: ImageSegmentedPickerViewModel

        @State private var query = ""
        @State private var isDuckAISelected: Bool
        @State private var isKeyboardVisible = false
        @State private var isInputFocused = false
        @State private var visibleSuggestionCount = 0
        @State private var suggestionTimerID = UUID()
        @State private var didRunInitialToggleAnimation = false
        @State private var isTransitioningOut = false
        private let defaultDuckAISelection: Bool
        private let suggestionRevealDelay: TimeInterval = 4
        private let suggestionStaggerDelay: TimeInterval = 0.5
        
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
            action: @escaping () -> Void,
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
                configuration: ImageSegmentedPickerConfiguration(),
                scrollProgress: defaultSelection ? 0 : 1,
                isScrollProgressDriven: false
            ))
        }

        var body: some View {
            VStack(spacing: 16) {
                Text(UserText.Onboarding.DuckAIQueryExperiment.title)
                    .font(Font(UIFont.daxTitle3()))
                    .multilineTextAlignment(.leading)
                    .foregroundColor(Color(designSystemColor: .textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                ImageSegmentedPickerView(viewModel: pickerViewModel)
                    .frame(width: 216, height: 38)
                    .onChange(of: pickerViewModel.selectedItem) { selectedItem in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isDuckAISelected = selectedItem == Self.pickerItems[1]
                        }
                    }
                    .onChange(of: isDuckAISelected) { isSelected in
                        let selection = isSelected ? Self.pickerItems[1] : Self.pickerItems[0]
                        if pickerViewModel.selectedItem != selection {
                            pickerViewModel.selectItem(selection)
                        }
                        pickerViewModel.updateScrollProgress(isSelected ? 1 : 0)
                        isInputFocused = true
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 3.67)

                queryField
                    .padding(.top, -12)
                    .padding(.bottom, 8)
                if visibleSuggestionCount > 0 {
                    suggestionChips
                }
            }
            .opacity(isTransitioningOut ? 0 : 1)
            .onAppear {
                isInputFocused = false
                registerEngagement()

                if !didRunInitialToggleAnimation {
                    didRunInitialToggleAnimation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isDuckAISelected = defaultDuckAISelection
                            isInputFocused = true
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .animation(suggestionAppearanceAnimation, value: visibleSuggestionCount)
            .animation(.easeInOut(duration: 0.2), value: isTransitioningOut)
        }

        private var queryField: some View {
            HStack(alignment: .bottom, spacing: 8) {
                OnboardingQueryField(
                    text: $query,
                    placeholder: isDuckAISelected
                    ? UserText.Onboarding.DuckAIQueryExperiment.aiPlaceholder
                    : UserText.Onboarding.DuckAIQueryExperiment.searchPlaceholder,
                    isFocused: $isInputFocused,
                    isSingleLine: !isDuckAISelected,
                    onSubmit: handlePrimaryAction
                )
                .frame(height: isDuckAISelected ? 56 : 26, alignment: isDuckAISelected ? .topLeading : .center)

                Button(action: handlePrimaryAction) {
                    Image(
                        uiImage: isDuckAISelected
                        ? DesignSystemImages.Glyphs.Size16.arrowRight
                        : DesignSystemImages.Glyphs.Size24.findSearchSmall
                    )
                        .renderingMode(.template)
                        .font(Font(UIFont.daxBodyBold()))
                        .foregroundColor(Color(designSystemColor: .iconsSecondary))
                        .opacity(isPrimaryActionEnabled ? 1 : 0.3)
                        .frame(width: 28, height: 28)
                        .offset(y: 1)
                }
                .buttonStyle(.plain)
                .disabled(!isPrimaryActionEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(designSystemColor: .surface))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(designSystemColor: .accent), lineWidth: 1.5)
            )
            .cornerRadius(14)
            .frame(width: 310.67)
            .shadow(color: queryFieldShadowColors.0, radius: 8, y: 2)
            .shadow(color: queryFieldShadowColors.1, radius: 4, y: 1)
            .animation(.easeInOut(duration: 0.2), value: isDuckAISelected)
        }

        private var suggestionChips: some View {
            VStack(spacing: 8) {
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
                    Spacer()
                }
                .foregroundColor(Color(designSystemColor: .accent))
                .padding(.horizontal, 14)
                .frame(width: 317.33, height: 46.33)
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(designSystemColor: .accent), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }

        private func storeSelection() {
            let onboardingProvider = OnboardingSearchExperience()
            onboardingProvider.storeAIChatSearchInputDuringOnboardingChoice(enable: isDuckAISelected)
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

        private var queryFieldShadowColors: (Color, Color) {
            (
                Color(designSystemColor: .shadowSecondary),
                Color(designSystemColor: .shadowTertiary)
            )
        }

        private var isPrimaryActionEnabled: Bool {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return isDuckAISelected || !trimmed.isEmpty
        }

        private func openSelectedExperience(prompt: String?, autoSend: Bool, promptSource: DuckAIQueryExperimentPromptSource) {
            storeSelection()

            if autoSend {
                measureQuerySubmissionAction(isDuckAISelected, promptSource)
            }

            isInputFocused = false
            dismissKeyboard()
            startExitTransitionAction(isDuckAISelected)

            withAnimation(.easeOut(duration: 0.2)) {
                isTransitioningOut = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.submitTransitionDelay) {
                if isDuckAISelected {
                    openAIChatAction(prompt, autoSend)
                    action()
                } else if let searchQuery = prompt, !searchQuery.isEmpty {
                    openSearchAction(searchQuery)
                    action()
                } else {
                    isTransitioningOut = false
                }
            }
        }

        private func registerEngagement() {
            guard !isTransitioningOut else { return }
            let token = UUID()
            suggestionTimerID = token
            visibleSuggestionCount = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + suggestionRevealDelay) {
                guard suggestionTimerID == token else { return }
                revealSuggestionsSequentially(token: token)
            }
        }

        private func revealSuggestionsSequentially(token: UUID) {
            for index in 1...3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + suggestionStaggerDelay * Double(index - 1)) {
                    guard suggestionTimerID == token else { return }
                    withAnimation(suggestionAppearanceAnimation) {
                        visibleSuggestionCount = index
                    }
                }
            }
        }

        private func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

}

private struct OnboardingQueryField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let isSingleLine: Bool
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .daxBodyRegular()
        textView.textColor = UIColor(designSystemColor: .textPrimary)
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.returnKeyType = .search

        context.coordinator.placeholderLabel.text = placeholder
        context.coordinator.placeholderLabel.font = textView.font
        context.coordinator.placeholderLabel.textColor = UIColor(designSystemColor: .textSecondary)
        context.coordinator.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(context.coordinator.placeholderLabel)
        NSLayoutConstraint.activate([
            context.coordinator.placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            context.coordinator.placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor)
        ])

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if context.coordinator.placeholderLabel.text != placeholder {
            context.coordinator.placeholderLabel.text = placeholder
        }
        context.coordinator.placeholderLabel.isHidden = !text.isEmpty
        context.coordinator.isSingleLine = isSingleLine
        uiView.returnKeyType = isSingleLine ? .search : .go
        uiView.textContainer.maximumNumberOfLines = isSingleLine ? 1 : 0
        uiView.textContainer.lineBreakMode = isSingleLine ? .byTruncatingTail : .byWordWrapping

        if isFocused {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, isSingleLine: isSingleLine, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool
        var isSingleLine: Bool
        private let onSubmit: () -> Void
        let placeholderLabel = UILabel()

        init(text: Binding<String>, isFocused: Binding<Bool>, isSingleLine: Bool, onSubmit: @escaping () -> Void) {
            _text = text
            _isFocused = isFocused
            self.isSingleLine = isSingleLine
            self.onSubmit = onSubmit
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text ?? ""
            placeholderLabel.isHidden = !text.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused = true
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

            guard isSingleLine else {
                return true
            }

            if replacement.contains("\n"), let currentText = textView.text, let swiftRange = Range(range, in: currentText) {
                let normalizedReplacement = replacement.replacingOccurrences(of: "\n", with: " ")
                let updated = currentText.replacingCharacters(in: swiftRange, with: normalizedReplacement)
                textView.text = updated
                text = updated
                placeholderLabel.isHidden = !updated.isEmpty
                return false
            }

            return true
        }
    }
}

// MARK: - View State

extension OnboardingView {

    enum ViewState: Equatable {
        case landing
        case onboarding(Intro)

        var intro: Intro? {
            switch self {
            case .landing:
                return nil
            case let .onboarding(intro):
                return intro
            }
        }
    }
    
}

extension OnboardingView.ViewState {
    
    struct Intro: Equatable {
        let type: IntroType
        let step: StepInfo
    }

}

extension OnboardingView.ViewState.Intro {

    enum IntroType: Equatable {
        case startOnboardingDialog(canSkipTutorial: Bool)
        case browsersComparisonDialog
        case addToDockPromoDialog
        case chooseAppIconDialog
        case chooseAddressBarPositionDialog
        case chooseSearchExperienceDialog
        case duckAIQueryExperimentDialog(defaultSelection: Bool)
    }

    struct StepInfo: Equatable {
        let currentStep: Int
        let totalSteps: Int

        static let hidden = StepInfo(currentStep: 0, totalSteps: 0)
    }

}

private extension OnboardingView.ViewState.Intro.IntroType {
    var isExperimentSearchScreen: Bool {
        if case .duckAIQueryExperimentDialog = self {
            return true
        } else {
            return false
        }
    }
}

// MARK: - Metrics

private enum Metrics {
    static let daxDialogDelay: TimeInterval = 2.0
    static let daxDialogVisibilityDelay: TimeInterval = 0.5
    static let comparisonChartAnimationDuration = 0.25
    static let submitTransitionDelay: TimeInterval = 0.42
    static let dialogVerticalOffsetPercentage = MetricBuilder<CGFloat>(default: 0.1).iPhoneSmallScreen(0.01)
    // Calibrated so experiment container top sits ~98pt below notch.
    static let experimentDialogTopOffset: CGFloat = -22
    static let chromeTopHeight: CGFloat = 58
    static let chromeBottomHeight: CGFloat = 92
    static let progressBarTrailingPadding: CGFloat = 16.0
    static let progressBarTopPadding: CGFloat = 12.0
}

// MARK: - Helpers

private extension View {

    func onboardingProgressIndicator(currentStep: Int, totalSteps: Int, isVisible: Bool = true) -> some View {
        overlay(alignment: .topTrailing) {
            OnboardingProgressIndicator(stepInfo: .init(currentStep: currentStep, totalSteps: totalSteps))
                .padding(.trailing, Metrics.progressBarTrailingPadding)
                .padding(.top, Metrics.progressBarTopPadding)
                .transition(.identity)
                .visibility(totalSteps == 0 || !isVisible ? .invisible : .visible)
        }
    }

}

// MARK: - Preview

struct OnboardingView_Previews: PreviewProvider {
    class MockDaxDialogDisabling: ContextualDaxDialogDisabling {
        func disableContextualDaxDialogs() {}
    }

    static var previews: some View {
        ForEach(ColorScheme.allCases, id: \.self) {
            OnboardingView(
                model: .init(
                    pixelReporter: OnboardingPixelReporter(),
                    systemSettingsPiPTutorialManager: SystemSettingsPiPTutorialManager(
                        playerView: UIView(),
                        videoPlayer: VideoPlayerCoordinator(configuration: VideoPlayerConfiguration()),
                        eventMapper: SystemSettingsPiPTutorialPixelHandler(),
                    ),
                    daxDialogsManager: MockDaxDialogDisabling()
                )
            )
            .preferredColorScheme($0)
        }
    }
}
