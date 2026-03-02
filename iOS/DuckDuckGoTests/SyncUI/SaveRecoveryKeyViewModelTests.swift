//
//  SaveRecoveryKeyViewModelTests.swift
//  DuckDuckGoTests
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
@testable import SyncUI_iOS

final class SaveRecoveryKeyViewModelTests: XCTestCase {

    func testWhenFeatureEnabledAndNoExistingDecisionThenPersistsDefaultEnabledDecision() {
        let persistSpy = AutoRestoreDecisionPersistSpy()

        _ = SaveRecoveryKeyViewModel(
            key: "test-key",
            showRecoveryPDFAction: {},
            onDismiss: {},
            isAutoRestoreFeatureEnabled: true,
            existingAutoRestoreDecision: nil,
            persistAutoRestoreDecision: persistSpy.persist(_:),
            presentLearnMore: {}
        )

        XCTAssertEqual(persistSpy.persistedDecisions, [true])
    }

    func testWhenFeatureEnabledAndExistingDecisionProvidedThenUsesDecisionWithoutPersisting() {
        let persistSpy = AutoRestoreDecisionPersistSpy()

        let sut = SaveRecoveryKeyViewModel(
            key: "test-key",
            showRecoveryPDFAction: {},
            onDismiss: {},
            isAutoRestoreFeatureEnabled: true,
            existingAutoRestoreDecision: false,
            persistAutoRestoreDecision: persistSpy.persist(_:),
            presentLearnMore: {}
        )

        XCTAssertFalse(sut.isAutoRestoreEnabled)
        XCTAssertTrue(persistSpy.persistedDecisions.isEmpty)
    }

    func testWhenFeatureDisabledAndNoExistingDecisionThenDoesNotPersistInitialDecision() {
        let persistSpy = AutoRestoreDecisionPersistSpy()

        _ = SaveRecoveryKeyViewModel(
            key: "test-key",
            showRecoveryPDFAction: {},
            onDismiss: {},
            isAutoRestoreFeatureEnabled: false,
            existingAutoRestoreDecision: nil,
            persistAutoRestoreDecision: persistSpy.persist(_:),
            presentLearnMore: {}
        )

        XCTAssertTrue(persistSpy.persistedDecisions.isEmpty)
    }

    func testWhenAutoRestoreToggledAndPersistSucceedsThenReturnsTrueAndUpdatesState() {
        let persistSpy = AutoRestoreDecisionPersistSpy()
        let sut = SaveRecoveryKeyViewModel(
            key: "test-key",
            showRecoveryPDFAction: {},
            onDismiss: {},
            isAutoRestoreFeatureEnabled: true,
            existingAutoRestoreDecision: true,
            persistAutoRestoreDecision: persistSpy.persist(_:),
            presentLearnMore: {}
        )

        let didPersist = sut.autoRestoreToggled(false)

        XCTAssertTrue(didPersist)
        XCTAssertFalse(sut.isAutoRestoreEnabled)
        XCTAssertEqual(persistSpy.persistedDecisions, [false])
    }

    func testWhenAutoRestoreToggledAndPersistFailsThenReturnsFalseAndKeepsOriginalState() {
        let persistSpy = AutoRestoreDecisionPersistSpy()
        persistSpy.result = false
        let sut = SaveRecoveryKeyViewModel(
            key: "test-key",
            showRecoveryPDFAction: {},
            onDismiss: {},
            isAutoRestoreFeatureEnabled: true,
            existingAutoRestoreDecision: true,
            persistAutoRestoreDecision: persistSpy.persist(_:),
            presentLearnMore: {}
        )

        let didPersist = sut.autoRestoreToggled(false)

        XCTAssertFalse(didPersist)
        XCTAssertTrue(sut.isAutoRestoreEnabled)
        XCTAssertEqual(persistSpy.persistedDecisions, [false])
    }

    func testWhenAutoRestoreToggledAndFeatureDisabledThenReturnsTrueWithoutPersisting() {
        let persistSpy = AutoRestoreDecisionPersistSpy()
        let sut = SaveRecoveryKeyViewModel(
            key: "test-key",
            showRecoveryPDFAction: {},
            onDismiss: {},
            isAutoRestoreFeatureEnabled: false,
            existingAutoRestoreDecision: true,
            persistAutoRestoreDecision: persistSpy.persist(_:),
            presentLearnMore: {}
        )

        let didPersist = sut.autoRestoreToggled(false)

        XCTAssertTrue(didPersist)
        XCTAssertTrue(persistSpy.persistedDecisions.isEmpty)
    }

    func testWhenPresentLearnMoreCalledThenForwardsAction() {
        var presentLearnMoreCalled = false
        let sut = SaveRecoveryKeyViewModel(
            key: "test-key",
            showRecoveryPDFAction: {},
            onDismiss: {},
            isAutoRestoreFeatureEnabled: true,
            existingAutoRestoreDecision: true,
            persistAutoRestoreDecision: { _ in true },
            presentLearnMore: {
                presentLearnMoreCalled = true
            }
        )

        sut.presentLearnMore()

        XCTAssertTrue(presentLearnMoreCalled)
    }
}

private final class AutoRestoreDecisionPersistSpy {
    var persistedDecisions: [Bool] = []
    var result = true

    func persist(_ decision: Bool) -> Bool {
        persistedDecisions.append(decision)
        return result
    }
}
