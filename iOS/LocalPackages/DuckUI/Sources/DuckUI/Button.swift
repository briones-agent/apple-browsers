//
//  Button.swift
//  DuckDuckGo
//
//  Copyright © 2017 DuckDuckGo. All rights reserved.
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
import DesignResourcesKit
import UIComponents

/// Visual appearance for DuckUI button styles. Set once at app launch from the
/// `brandRefreshButtons` feature flag; reads happen-after that single write.
public enum DuckUIAppearance: Sendable {
    case legacy
    case refresh

    nonisolated(unsafe) public static var current: DuckUIAppearance = .legacy
}

/// Refresh palette tokens. Hex literals match the Figma spec exactly until the rebrand
/// is promoted into `DefaultColorPalette` proper. TODO(brand-refresh): replace with
/// `Color(singleUseColor: .rebranding(...))` once the matching tokens land.
private enum RefreshColors {
    /// Light/Accent/Primary
    static let accent = Color(0x1074CC)
    /// Light/Accent-Brand/Primary
    static let brandAccent = Color(0xF05F2B)
    /// Pressed-state shade for the standard accent (Pondwater 70).
    static let accentPressed = Color(0x045EB2)
    /// Pressed-state shade for the brand accent (Mandarin 60).
    static let brandAccentPressed = Color(0xCC3B0A)
    /// Light/Destructive/Primary
    static let destructive = Color(0xD83544)
    /// Pressed-state shade for the destructive color (Red 60).
    static let destructivePressed = Color(0xCA2B3D)
    /// Text color on filled accent backgrounds.
    static let onAccentText = Color.white
}

private struct PrimaryButtonColors {
    let standard: Color
    let pressed: Color
    let disabled: Color
    let text: Color
    let textDisabled: Color

    static let primary = PrimaryButtonColors(
        standard: Color(designSystemColor: .buttonsPrimaryDefault),
        pressed: Color(designSystemColor: .buttonsPrimaryPressed),
        disabled: Color(designSystemColor: .buttonsPrimaryDisabled),
        text: Color(designSystemColor: .buttonsPrimaryText),
        textDisabled: Color(designSystemColor: .buttonsPrimaryTextDisabled)
    )

    static let destructive = PrimaryButtonColors(
        standard: Color(designSystemColor: .destructivePrimary),
        pressed: Color(designSystemColor: .buttonsDestructivePrimaryPressed),
        disabled: Color(designSystemColor: .destructivePrimary).opacity(0.36),
        text: Color(designSystemColor: .buttonsWhite),
        textDisabled: Color(designSystemColor: .buttonsWhite).opacity(0.36)
    )

    /// Refresh appearance, standard accent — Light/Accent/Primary (#1074CC).
    static let refreshStandard = PrimaryButtonColors(
        standard: RefreshColors.accent,
        pressed: RefreshColors.accentPressed,
        disabled: Color(designSystemColor: .buttonsPrimaryDisabled),
        text: RefreshColors.onAccentText,
        textDisabled: Color(designSystemColor: .buttonsPrimaryTextDisabled)
    )

    /// Refresh appearance, brand accent — Light/Accent-Brand/Primary (#F05F2B).
    static let refreshBrand = PrimaryButtonColors(
        standard: RefreshColors.brandAccent,
        pressed: RefreshColors.brandAccentPressed,
        disabled: Color(designSystemColor: .buttonsPrimaryDisabled),
        text: RefreshColors.onAccentText,
        textDisabled: Color(designSystemColor: .buttonsPrimaryTextDisabled)
    )

    /// Refresh appearance, destructive — Light/Destructive/Primary (#D83544).
    static let refreshDestructive = PrimaryButtonColors(
        standard: RefreshColors.destructive,
        pressed: RefreshColors.destructivePressed,
        disabled: Color(designSystemColor: .destructivePrimary).opacity(0.36),
        text: RefreshColors.onAccentText,
        textDisabled: Color(designSystemColor: .buttonsWhite).opacity(0.36)
    )
}

@ViewBuilder
private func makePrimaryButtonBody(
    configuration: ButtonStyleConfiguration,
    colors: PrimaryButtonColors,
    disabled: Bool,
    compact: Bool,
    fullWidth: Bool
) -> some View {
    let backgroundColor = disabled ? colors.disabled : colors.standard
    let foregroundColor = disabled ? colors.textDisabled : colors.text

    configuration.label
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .lineLimit(nil)
        .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
        .foregroundColor(foregroundColor)
        .padding(.vertical)
        .padding(.horizontal, fullWidth ? nil : 24)
        .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil, maxHeight: compact ? Consts.height - 10 : Consts.height)
        .background(configuration.isPressed ? colors.pressed : backgroundColor)
        .cornerRadius(Consts.cornerRadius)
}

/// Refresh body: pill shape (corner radius = height/2), refresh palette colors.
@ViewBuilder
private func makeRefreshPrimaryButtonBody(
    configuration: ButtonStyleConfiguration,
    colors: PrimaryButtonColors,
    disabled: Bool,
    compact: Bool,
    fullWidth: Bool
) -> some View {
    let backgroundColor = disabled ? colors.disabled : colors.standard
    let foregroundColor = disabled ? colors.textDisabled : colors.text
    let activeBackground = configuration.isPressed ? colors.pressed : backgroundColor

    configuration.label
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .lineLimit(nil)
        .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
        .foregroundColor(foregroundColor)
        .padding(.vertical)
        .padding(.horizontal, fullWidth ? nil : 24)
        .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil, maxHeight: compact ? Consts.height - 10 : Consts.height)
        .background(Capsule().fill(activeBackground))
        .contentShape(Capsule())
}

public struct PrimaryButtonStyle: ButtonStyle {

    /// Accent variant for the refresh appearance. Ignored when appearance is `.legacy`.
    public enum Accent: Sendable {
        /// Light/Accent/Primary (#1074CC).
        case standard
        /// Light/Accent-Brand/Primary (#F05F2B).
        case brand
    }

    let disabled: Bool
    let compact: Bool
    let fullWidth: Bool
    let accent: Accent

    public init(
        disabled: Bool = false,
        compact: Bool = false,
        fullWidth: Bool = true,
        accent: Accent = .standard
    ) {
        self.disabled = disabled
        self.compact = compact
        self.fullWidth = fullWidth
        self.accent = accent
    }

    public func makeBody(configuration: Configuration) -> some View {
        switch DuckUIAppearance.current {
        case .legacy:
            makePrimaryButtonBody(
                configuration: configuration,
                colors: .primary,
                disabled: disabled,
                compact: compact,
                fullWidth: fullWidth
            )
        case .refresh:
            makeRefreshPrimaryButtonBody(
                configuration: configuration,
                colors: accent == .brand ? .refreshBrand : .refreshStandard,
                disabled: disabled,
                compact: compact,
                fullWidth: fullWidth
            )
        }
    }
}

public struct PrimaryDestructiveButtonStyle: ButtonStyle {
    let disabled: Bool
    let compact: Bool
    let fullWidth: Bool

    public init(disabled: Bool = false, compact: Bool = false, fullWidth: Bool = true) {
        self.disabled = disabled
        self.compact = compact
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        switch DuckUIAppearance.current {
        case .legacy:
            makePrimaryButtonBody(
                configuration: configuration,
                colors: .destructive,
                disabled: disabled,
                compact: compact,
                fullWidth: fullWidth
            )
        case .refresh:
            makeRefreshPrimaryButtonBody(
                configuration: configuration,
                colors: .refreshDestructive,
                disabled: disabled,
                compact: compact,
                fullWidth: fullWidth
            )
        }
    }
}

public struct SecondaryDestructiveButtonStyle: ButtonStyle {
    let disabled: Bool
    let compact: Bool
    let fullWidth: Bool

    public init(disabled: Bool = false, compact: Bool = false, fullWidth: Bool = true) {
        self.disabled = disabled
        self.compact = compact
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        switch DuckUIAppearance.current {
        case .legacy:
            makeLegacyBody(configuration: configuration)
        case .refresh:
            makeRefreshBody(configuration: configuration)
        }
    }

    @ViewBuilder
    private func makeLegacyBody(configuration: Configuration) -> some View {
        let destructiveColor = Color(designSystemColor: .destructivePrimary)
        let disabledColor = destructiveColor.opacity(0.36)
        let borderColor = disabled ? disabledColor : destructiveColor
        let foregroundColor = disabled ? disabledColor : destructiveColor
        let pressedBackgroundColor = destructiveColor.opacity(0.1)

        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(foregroundColor)
            .padding(.vertical)
            .padding(.horizontal, fullWidth ? nil : 24)
            .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .background(configuration.isPressed ? pressedBackgroundColor : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Consts.cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
            .cornerRadius(Consts.cornerRadius)
            .contentShape(RoundedRectangle(cornerRadius: Consts.cornerRadius))
    }

    /// Refresh secondary destructive: standard secondary fill, destructive text.
    @ViewBuilder
    private func makeRefreshBody(configuration: Configuration) -> some View {
        let standardBackgroundColor = Color(singleUseColor: .rebranding(.controlsFillPrimary))
        let pressedBackgroundColor = Color(singleUseColor: .rebranding(.buttonsSecondaryPressed))
        let activeBackground = configuration.isPressed ? pressedBackgroundColor : standardBackgroundColor
        let activeForeground: Color = disabled
            ? RefreshColors.destructive.opacity(0.36)
            : (configuration.isPressed ? RefreshColors.destructivePressed : RefreshColors.destructive)

        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(activeForeground)
            .padding(.vertical)
            .padding(.horizontal, fullWidth ? nil : 24)
            .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .background(Capsule().fill(activeBackground))
            .contentShape(Capsule())
    }
}

// This style seems to be deprecated - you probably want to use SecondaryWireButtonStyle.
// Reach out to designers.
public struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }
    
    private var backgoundColor: Color {
        colorScheme == .light ? Color.white : Color(baseColor: .gray70)
    }

    private var foregroundColor: Color {
        colorScheme == .light ? Color(baseColor: .blue50) : .white
    }

    @ViewBuilder
    func compactPadding(view: some View) -> some View {
        if compact {
            view
        } else {
            view.padding()
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        compactPadding(view: configuration.label)
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(configuration.isPressed ? foregroundColor.opacity(Consts.pressedOpacity) : foregroundColor.opacity(1))
            .padding()
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .cornerRadius(Consts.cornerRadius)
    }
}

public struct SecondaryFillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    let disabled: Bool
    let compact: Bool
    let fullWidth: Bool
    let isFreeform: Bool

    public init(disabled: Bool = false, compact: Bool = false, fullWidth: Bool = true, isFreeform: Bool = false) {
        self.disabled = disabled
        self.compact = compact
        self.fullWidth = fullWidth
        self.isFreeform = isFreeform
    }

    public func makeBody(configuration: Configuration) -> some View {
        switch DuckUIAppearance.current {
        case .legacy:
            makeLegacyBody(configuration: configuration)
        case .refresh:
            makeRefreshBody(configuration: configuration)
        }
    }

    @ViewBuilder
    private func makeLegacyBody(configuration: Configuration) -> some View {
        let standardBackgroundColor = Color(designSystemColor: .buttonsSecondaryFillDefault)
        let pressedBackgroundColor = Color(designSystemColor: .buttonsSecondaryFillPressed)
        let disabledBackgroundColor = Color(designSystemColor: .buttonsSecondaryFillDisabled)
        let defaultForegroundColor = Color(designSystemColor: .buttonsSecondaryFillText)
        let disabledForegroundColor = Color(designSystemColor: .buttonsSecondaryFillTextDisabled)
        let backgroundColor = disabled ? disabledBackgroundColor : standardBackgroundColor
        let foregroundColor = disabled ? disabledForegroundColor : defaultForegroundColor

        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(configuration.isPressed ? defaultForegroundColor : foregroundColor)
            .if(!isFreeform) { view in
                view
                    .padding(.vertical)
                    .padding(.horizontal, fullWidth ? nil : 24)
                    .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil, maxHeight: compact ? Consts.height - 10 : Consts.height)
            }
            .background(configuration.isPressed ? pressedBackgroundColor : backgroundColor)
            .cornerRadius(Consts.cornerRadius)
    }

    /// Refresh secondary: Light/Control/Fill-Primary background, near-black text, pill shape.
    @ViewBuilder
    private func makeRefreshBody(configuration: Configuration) -> some View {
        let standardBackgroundColor = Color(singleUseColor: .rebranding(.controlsFillPrimary))
        let pressedBackgroundColor = Color(singleUseColor: .rebranding(.buttonsSecondaryPressed))
        let foregroundColor = Color(singleUseColor: .rebranding(.buttonsSecondaryText))
        let activeBackground = configuration.isPressed ? pressedBackgroundColor : standardBackgroundColor
        let activeForeground = disabled ? foregroundColor.opacity(0.36) : foregroundColor

        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(activeForeground)
            .if(!isFreeform) { view in
                view
                    .padding(.vertical)
                    .padding(.horizontal, fullWidth ? nil : 24)
                    .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil, maxHeight: compact ? Consts.height - 10 : Consts.height)
            }
            .background(Capsule().fill(activeBackground))
            .contentShape(Capsule())
    }
}

public struct GhostButtonStyle: ButtonStyle {

    let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        switch DuckUIAppearance.current {
        case .legacy:
            makeLegacyBody(configuration: configuration)
        case .refresh:
            makeRefreshBody(configuration: configuration)
        }
    }

    @ViewBuilder
    private func makeLegacyBody(configuration: Configuration) -> some View {
        let foreground = configuration.isPressed
            ? Color(designSystemColor: .buttonsGhostTextPressed)
            : Color(designSystemColor: .buttonsGhostText)
        let background: Color = configuration.isPressed
            ? Color(designSystemColor: .buttonsGhostPressedFill)
            : .clear

        configuration.label
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(foreground)
            .padding()
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .background(background)
            .cornerRadius(Consts.cornerRadius)
            .contentShape(Rectangle())
    }

    /// Refresh ghost: no background, text in Light/Accent/Primary, pill press affordance.
    @ViewBuilder
    private func makeRefreshBody(configuration: Configuration) -> some View {
        let textDefault = RefreshColors.accent
        let textPressed = RefreshColors.accentPressed
        let pressedFill = RefreshColors.accent.opacity(0.12)
        let activeBackground: Color = configuration.isPressed ? pressedFill : .clear
        let activeForeground = configuration.isPressed ? textPressed : textDefault

        configuration.label
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(activeForeground)
            .padding()
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .background(Capsule().fill(activeBackground))
            .contentShape(Capsule())
    }
}

public struct GhostDestructiveButtonStyle: ButtonStyle {

    let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        switch DuckUIAppearance.current {
        case .legacy:
            makeLegacyBody(configuration: configuration)
        case .refresh:
            makeRefreshBody(configuration: configuration)
        }
    }

    @ViewBuilder
    private func makeLegacyBody(configuration: Configuration) -> some View {
        let foreground = configuration.isPressed
            ? Color(designSystemColor: .buttonsDeleteGhostTextPressed)
            : Color(designSystemColor: .buttonsDeleteGhostText)
        let background: Color = configuration.isPressed
            ? Color(designSystemColor: .buttonsDeleteGhostPressedFill)
            : .clear

        configuration.label
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(foreground)
            .padding()
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .background(background)
            .cornerRadius(Consts.cornerRadius)
            .contentShape(Rectangle())
    }

    /// Refresh ghost destructive: no background, destructive text color, pill press affordance.
    @ViewBuilder
    private func makeRefreshBody(configuration: Configuration) -> some View {
        let textDefault = RefreshColors.destructive
        let textPressed = RefreshColors.destructivePressed
        let pressedFill = RefreshColors.destructive.opacity(0.12)
        let activeBackground: Color = configuration.isPressed ? pressedFill : .clear
        let activeForeground = configuration.isPressed ? textPressed : textDefault

        configuration.label
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(activeForeground)
            .padding()
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .background(Capsule().fill(activeBackground))
            .contentShape(Capsule())
    }
}

public struct GhostAltButtonStyle: ButtonStyle {

    let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font(UIFont.boldAppFont(ofSize: Consts.fontSize)))
            .foregroundColor(Color(designSystemColor: .textSecondary))
            .padding()
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: compact ? Consts.height - 10 : Consts.height)
            .background(backgroundColor(configuration.isPressed))
            .cornerRadius(Consts.cornerRadius)
            .contentShape(Rectangle()) // Makes whole button area tappable, when there's no background
    }
    
    private func backgroundColor(_ isPressed: Bool) -> Color {
        isPressed ?  Color(UIColor(designSystemColor: .controlsFillPrimary)) : .clear
    }
}

private enum Consts {
    static let cornerRadius: CGFloat = 12
    static let height: CGFloat = 50
    static let fontSize: CGFloat = 15
    static let pressedOpacity: CGFloat = 0.7
    static let ghostPressedBackgroundOpacity: CGFloat = 0.09
}
