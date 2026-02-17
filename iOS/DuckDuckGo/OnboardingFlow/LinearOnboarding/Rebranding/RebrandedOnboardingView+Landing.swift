//
//  RebrandedOnboardingView+Landing.swift
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

import SwiftUI
import Onboarding
import Lottie

// MARK: - Metrics

private enum LandingViewMetrics {
    static let logoSize: CGFloat = 90
    static let topPadding: CGFloat = 80
    static let welcomeBottomPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 24
    static let titleMaxWidth: CGFloat = 300
    static let illustrationHeightRatio: CGFloat = 0.62
    static let minIllustrationHeight: CGFloat = 430
    static let maxIllustrationHeight: CGFloat = 560
    static let illustrationWidth: CGFloat = 500
}

private enum LandingViewAssets {
    static let illustrationAnimation = "OnboardingLandingIllustrationAnimation"
    static let logoAnimation = "OnboardingLandingLogoAnimation"
}

// MARK: - Component Animation

private struct ComponentAnimationState {
    var scale: CGFloat
    var offset: CGSize  
    var opacity: Double

    static func start(
        scale: CGFloat = 1.0,
        offset: CGSize = .zero,
        opacity: Double = 0.0
    ) -> ComponentAnimationState {
        ComponentAnimationState(scale: scale, offset: offset, opacity: opacity)
    }

    static func end(
        scale: CGFloat = 1.0,
        offset: CGSize = .zero,
        opacity: Double = 1.0
    ) -> ComponentAnimationState {
        ComponentAnimationState(scale: scale, offset: offset, opacity: opacity)
    }
}

// MARK: - Start / End States

private enum LandingAnimationStates {
    static let logoStart = ComponentAnimationState.start(scale: 25.0 / 14.0, opacity: 0.0)
    static let textStart = ComponentAnimationState.start(scale: 2.0, opacity: 0.0)
    static let textOffsetStart: CGSize = CGSize(width: 0, height: 49)
    static let illustrationStart = ComponentAnimationState.start()
    static let illustrationOffsetStart: CGSize = CGSize(width: 325, height: 204)
    static let logoEnd = ComponentAnimationState.end()
    static let textEnd = ComponentAnimationState.end()
    static let illustrationEnd = ComponentAnimationState.end()
}

// MARK: - Timing (from AE specs at 30fps)

private enum LandingAnimationTiming {
    static let logoAnimation: Animation = .timingCurve(0.26, 0.64, 0.48, 1.00, duration: 0.667).delay(0.4)
    static let textOffsetAnimation: Animation = .timingCurve(0.40, 2.70, 0.74, 1.00, duration: 0.5).delay(0.4)
    static let textOpacityAnimation: Animation = .timingCurve(0.33, 0.00, 0.67, 1.00, duration: 0.2).delay(0.4)
    static let illustrationAnimation: Animation = .timingCurve(0.10, 0.85, 0.64, 0.99, duration: 0.7).delay(0.133)
}

// MARK: - Landing View

extension OnboardingRebranding.OnboardingView {

    struct LandingView: View {
        @Environment(\.onboardingTheme) private var onboardingTheme

        let animationNamespace: Namespace.ID

        @State private var logo = LandingAnimationStates.logoStart
        @State private var text = LandingAnimationStates.textStart
        @State private var textOffset = LandingAnimationStates.textOffsetStart
        @State private var illustration = LandingAnimationStates.illustrationStart
        @State private var illustrationOffset = LandingAnimationStates.illustrationOffsetStart

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    welcomeView
                        .padding(.top, LandingViewMetrics.topPadding)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                    illustrationView(width: proxy.size.width, height: illustrationHeight(for: proxy.size.height))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .onAppear {
                animateEntrance()
            }
        }

        // MARK: - Welcome (logo + text)

        private var welcomeView: some View {
            VStack(alignment: .center, spacing: LandingViewMetrics.welcomeBottomPadding) {

                // Logo Lottie (stopped at last frame)
                LandingLogoAnimationView(lottieAsset: LandingViewAssets.logoAnimation)
                    .matchedGeometryEffect(id: OnboardingView.daxGeometryEffectID, in: animationNamespace)
                    .frame(width: LandingViewMetrics.logoSize, height: LandingViewMetrics.logoSize)
                    .scaleEffect(logo.scale)
                    .opacity(logo.opacity)

                // Text
                Text(UserText.onboardingWelcomeHeader)
                    .font(onboardingTheme.typography.largeTitle)
                    .foregroundStyle(onboardingTheme.colorPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: LandingViewMetrics.titleMaxWidth)
                    .offset(textOffset)
                    .opacity(text.opacity)
            }
            .padding(.horizontal, LandingViewMetrics.horizontalPadding)
        }

        // MARK: - Illustration (mountains Lottie)

        private func illustrationView(width: CGFloat, height: CGFloat) -> some View {
            LandingIllustrationContainerView(
                lottieAsset: LandingViewAssets.illustrationAnimation
            )
            .frame(width: LandingViewMetrics.illustrationWidth)
            .offset(illustrationOffset)
            .opacity(illustration.opacity)
            .allowsHitTesting(false)
        }

        // MARK: - Animation Sequencing

        private func animateEntrance() {
            // Logo: scale + opacity
            withAnimation(LandingAnimationTiming.logoAnimation) {
                logo = LandingAnimationStates.logoEnd
            }

            // Text: offset with overshoot curve
            withAnimation(LandingAnimationTiming.textOffsetAnimation) {
                textOffset = .zero
            }
            // Text: opacity with separate curve
            withAnimation(LandingAnimationTiming.textOpacityAnimation) {
                text = LandingAnimationStates.textEnd
            }

            // Illustration: position slide-in
            withAnimation(LandingAnimationTiming.illustrationAnimation) {
                illustrationOffset = .zero
                illustration = LandingAnimationStates.illustrationEnd
            }
        }

        private func illustrationHeight(for screenHeight: CGFloat) -> CGFloat {
            let scaledHeight = screenHeight * LandingViewMetrics.illustrationHeightRatio
            return min(max(scaledHeight, LandingViewMetrics.minIllustrationHeight), LandingViewMetrics.maxIllustrationHeight)
        }
    }
}

// MARK: - Lottie Container

// MARK: - Logo Lottie

private struct LandingLogoAnimationView: UIViewRepresentable {

    let lottieAsset: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let animationView = LottieAnimationView()
        animationView.animation = LottieAnimation.asset(lottieAsset)
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .playOnce
        animationView.isUserInteractionEnabled = false
        animationView.currentProgress = 1.0
        animationView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.topAnchor.constraint(equalTo: container.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            animationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let animationView = uiView.subviews.first as? LottieAnimationView else { return }
        if animationView.animation == nil {
            animationView.animation = LottieAnimation.asset(lottieAsset)
            animationView.currentProgress = 1.0
        }
    }
}

// MARK: - Illustration Lottie

private struct LandingIllustrationContainerView: UIViewRepresentable {

    let lottieAsset: String

    func makeUIView(context: Context) -> LottieAnimationView {
        let animationView = LottieAnimationView()
        animationView.animation = LottieAnimation.asset(lottieAsset)
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .playOnce
        animationView.isUserInteractionEnabled = false

        animationView.currentProgress = 0.0
        DispatchQueue.main.async {
            animationView.play(fromProgress: 0, toProgress: 1, loopMode: .playOnce)
        }

        return animationView
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        if uiView.animation == nil {
            uiView.animation = LottieAnimation.asset(lottieAsset)
            uiView.play(fromProgress: 0, toProgress: 1, loopMode: .playOnce)
        }
    }
}
