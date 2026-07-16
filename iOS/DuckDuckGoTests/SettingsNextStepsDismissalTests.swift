//
//  SettingsNextStepsDismissalTests.swift
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

import XCTest
@testable import DuckDuckGo

/// Covers the "+1 day after tap" dismissal rule for the Settings "Next Steps" instructional
/// items (Add to Dock / Add Widget). See `SettingsViewModel.hasTapDismissalElapsed`.
final class SettingsNextStepsDismissalTests: XCTestCase {

    private let oneDay: TimeInterval = 24 * 60 * 60
    private let tappedAt: TimeInterval = 1_000_000

    func testItemStaysVisibleWhenNeverTapped() {
        XCTAssertFalse(SettingsViewModel.hasTapDismissalElapsed(tappedAt: nil, now: tappedAt, interval: oneDay))
    }

    func testItemStaysVisibleBeforeIntervalElapses() {
        XCTAssertFalse(SettingsViewModel.hasTapDismissalElapsed(tappedAt: tappedAt,
                                                                now: tappedAt + oneDay - 1,
                                                                interval: oneDay))
    }

    func testItemDismissesExactlyAtInterval() {
        XCTAssertTrue(SettingsViewModel.hasTapDismissalElapsed(tappedAt: tappedAt,
                                                               now: tappedAt + oneDay,
                                                               interval: oneDay))
    }

    func testItemDismissesAfterInterval() {
        XCTAssertTrue(SettingsViewModel.hasTapDismissalElapsed(tappedAt: tappedAt,
                                                               now: tappedAt + oneDay + 60,
                                                               interval: oneDay))
    }

    func testItemStaysVisibleWhenClockMovesBackwards() {
        // Defensive: if the device clock has moved earlier than the recorded tap, keep showing.
        XCTAssertFalse(SettingsViewModel.hasTapDismissalElapsed(tappedAt: tappedAt,
                                                                now: tappedAt - 500,
                                                                interval: oneDay))
    }

    // MARK: - hasInstallGracePeriodElapsed (Next Steps "Hide" 14-day install gate)

    private let fourteenDays: TimeInterval = 14 * 24 * 60 * 60
    private let installedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testHideButtonHiddenWhenInstallDateMissing() {
        XCTAssertFalse(SettingsViewModel.hasInstallGracePeriodElapsed(installDate: nil,
                                                                      now: installedAt,
                                                                      requiredInterval: fourteenDays))
    }

    func testHideButtonHiddenJustBeforeGracePeriodElapses() {
        let now = Date(timeIntervalSinceReferenceDate: installedAt.timeIntervalSinceReferenceDate + fourteenDays - 1)
        XCTAssertFalse(SettingsViewModel.hasInstallGracePeriodElapsed(installDate: installedAt,
                                                                      now: now,
                                                                      requiredInterval: fourteenDays))
    }

    func testHideButtonAppearsExactlyAtGracePeriod() {
        let now = Date(timeIntervalSinceReferenceDate: installedAt.timeIntervalSinceReferenceDate + fourteenDays)
        XCTAssertTrue(SettingsViewModel.hasInstallGracePeriodElapsed(installDate: installedAt,
                                                                     now: now,
                                                                     requiredInterval: fourteenDays))
    }

    func testHideButtonAppearsWellAfterGracePeriod() {
        let now = Date(timeIntervalSinceReferenceDate: installedAt.timeIntervalSinceReferenceDate + fourteenDays * 3)
        XCTAssertTrue(SettingsViewModel.hasInstallGracePeriodElapsed(installDate: installedAt,
                                                                     now: now,
                                                                     requiredInterval: fourteenDays))
    }

    func testHideButtonHiddenWhenClockMovesBackwardsBeforeInstall() {
        // Defensive: if the device clock reads earlier than the install date, keep the button hidden.
        let now = Date(timeIntervalSinceReferenceDate: installedAt.timeIntervalSinceReferenceDate - 500)
        XCTAssertFalse(SettingsViewModel.hasInstallGracePeriodElapsed(installDate: installedAt,
                                                                      now: now,
                                                                      requiredInterval: fourteenDays))
    }
}
