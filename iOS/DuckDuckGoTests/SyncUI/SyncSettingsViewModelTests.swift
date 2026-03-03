//
//  SyncSettingsViewModelTests.swift
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

import Combine
import CoreGraphics
import XCTest
@testable import SyncUI_iOS

@MainActor
final class SyncSettingsViewModelTests: XCTestCase {

    func testWhenAutoRestoreFeatureEnabledAndExistingDecisionThenInitialStateMatchesProvider() {
        let autoRestoreProvider = MockSyncAutoRestoreHandler()
        autoRestoreProvider.isAutoRestoreFeatureEnabled = true
        autoRestoreProvider.existingAutoRestoreDecision = true

        let sut = makeSut(autoRestoreProvider: autoRestoreProvider)

        XCTAssertTrue(sut.isAutoRestoreFeatureAvailable)
        XCTAssertTrue(sut.isAutoRestoreEnabled)
        XCTAssertEqual(sut.autoRestoreStatusText, UserText.autoRestoreStatusOn)
    }

    func testWhenRequestAutoRestoreUpdateAndDecisionUnchangedThenDoesNothing() {
        let autoRestoreProvider = MockSyncAutoRestoreHandler()
        autoRestoreProvider.isAutoRestoreFeatureEnabled = true
        autoRestoreProvider.existingAutoRestoreDecision = false
        let delegate = SyncSettingsViewModelDelegateSpy()
        let sut = makeSut(autoRestoreProvider: autoRestoreProvider, delegate: delegate)

        sut.requestAutoRestoreUpdate(enabled: false)

        XCTAssertFalse(sut.isAutoRestoreUpdating)
        XCTAssertTrue(autoRestoreProvider.persistedDecisions.isEmpty)
    }

    func testWhenRequestAutoRestoreUpdateAndAuthenticationSucceedsThenPersistsAndUpdatesState() async {
        let autoRestoreProvider = MockSyncAutoRestoreHandler()
        autoRestoreProvider.isAutoRestoreFeatureEnabled = true
        autoRestoreProvider.existingAutoRestoreDecision = false
        let delegate = SyncSettingsViewModelDelegateSpy()
        let sut = makeSut(autoRestoreProvider: autoRestoreProvider, delegate: delegate)

        let completionExpectation = expectation(description: "Auto-restore update completes")
        var sawUpdatingState = false
        let cancellable = sut.$isAutoRestoreUpdating
            .dropFirst()
            .sink { isUpdating in
                if isUpdating {
                    sawUpdatingState = true
                } else if sawUpdatingState {
                    completionExpectation.fulfill()
                }
            }

        sut.requestAutoRestoreUpdate(enabled: true)
        await fulfillment(of: [completionExpectation], timeout: 1.0)
        _ = cancellable

        XCTAssertEqual(autoRestoreProvider.persistedDecisions, [true])
        XCTAssertTrue(sut.isAutoRestoreEnabled)
        XCTAssertFalse(sut.isAutoRestoreUpdating)
    }

    func testWhenRequestAutoRestoreUpdateAndAuthenticationFailsThenDoesNotPersistOrUpdateState() async {
        let autoRestoreProvider = MockSyncAutoRestoreHandler()
        autoRestoreProvider.isAutoRestoreFeatureEnabled = true
        autoRestoreProvider.existingAutoRestoreDecision = false
        let delegate = SyncSettingsViewModelDelegateSpy()
        delegate.authenticationError = SyncSettingsViewModel.UserAuthenticationError.authFailed
        let sut = makeSut(autoRestoreProvider: autoRestoreProvider, delegate: delegate)

        let completionExpectation = expectation(description: "Auto-restore update ends after auth failure")
        var sawUpdatingState = false
        let cancellable = sut.$isAutoRestoreUpdating
            .dropFirst()
            .sink { isUpdating in
                if isUpdating {
                    sawUpdatingState = true
                } else if sawUpdatingState {
                    completionExpectation.fulfill()
                }
            }

        sut.requestAutoRestoreUpdate(enabled: true)
        await fulfillment(of: [completionExpectation], timeout: 1.0)
        _ = cancellable

        XCTAssertTrue(autoRestoreProvider.persistedDecisions.isEmpty)
        XCTAssertFalse(sut.isAutoRestoreEnabled)
        XCTAssertFalse(sut.isAutoRestoreUpdating)
    }

    func testWhenRequestAutoRestoreUpdateAndPersistFailsThenDoesNotUpdateState() async {
        let autoRestoreProvider = MockSyncAutoRestoreHandler()
        autoRestoreProvider.isAutoRestoreFeatureEnabled = true
        autoRestoreProvider.existingAutoRestoreDecision = false
        autoRestoreProvider.persistError = SyncSettingsViewModelTestsError.expected
        let delegate = SyncSettingsViewModelDelegateSpy()
        let sut = makeSut(autoRestoreProvider: autoRestoreProvider, delegate: delegate)

        let completionExpectation = expectation(description: "Auto-restore update ends after persist failure")
        var sawUpdatingState = false
        let cancellable = sut.$isAutoRestoreUpdating
            .dropFirst()
            .sink { isUpdating in
                if isUpdating {
                    sawUpdatingState = true
                } else if sawUpdatingState {
                    completionExpectation.fulfill()
                }
            }

        sut.requestAutoRestoreUpdate(enabled: true)
        await fulfillment(of: [completionExpectation], timeout: 1.0)
        _ = cancellable

        XCTAssertTrue(autoRestoreProvider.persistedDecisions.isEmpty)
        XCTAssertFalse(sut.isAutoRestoreEnabled)
        XCTAssertFalse(sut.isAutoRestoreUpdating)
    }

    func testWhenRefreshAutoRestoreDecisionStateAndFeatureUnavailableThenStateResetsToFalse() {
        let autoRestoreProvider = MockSyncAutoRestoreHandler()
        autoRestoreProvider.isAutoRestoreFeatureEnabled = false
        autoRestoreProvider.existingAutoRestoreDecision = true
        let sut = makeSut(autoRestoreProvider: autoRestoreProvider)
        sut.isAutoRestoreEnabled = true

        sut.refreshAutoRestoreDecisionState()

        XCTAssertFalse(sut.isAutoRestoreEnabled)
    }

    func testWhenRefreshAutoRestoreDecisionStateAndDecisionChangesThenStateUpdates() {
        let autoRestoreProvider = MockSyncAutoRestoreHandler()
        autoRestoreProvider.isAutoRestoreFeatureEnabled = true
        autoRestoreProvider.existingAutoRestoreDecision = false
        let sut = makeSut(autoRestoreProvider: autoRestoreProvider)

        autoRestoreProvider.existingAutoRestoreDecision = true
        sut.refreshAutoRestoreDecisionState()

        XCTAssertTrue(sut.isAutoRestoreEnabled)
        XCTAssertEqual(sut.autoRestoreStatusText, UserText.autoRestoreStatusOn)
    }

    private func makeSut(autoRestoreProvider: MockSyncAutoRestoreHandler,
                         delegate: SyncSettingsViewModelDelegateSpy? = nil) -> SyncSettingsViewModel {
        let model = SyncSettingsViewModel(
            isOnDevEnvironment: { false },
            switchToProdEnvironment: {},
            autoRestoreProvider: autoRestoreProvider
        )
        model.delegate = delegate
        return model
    }
}

private final class SyncSettingsViewModelDelegateSpy: SyncManagementViewModelDelegate {

    var authenticationError: Error?

    var syncBookmarksPausedTitle: String?
    var syncCredentialsPausedTitle: String?
    var syncCreditCardsPausedTitle: String?
    var syncPausedTitle: String?
    var syncBookmarksPausedDescription: String?
    var syncCredentialsPausedDescription: String?
    var syncCreditCardsPausedDescription: String?
    var syncPausedDescription: String?
    var syncBookmarksPausedButtonTitle: String?
    var syncCredentialsPausedButtonTitle: String?
    var syncCreditCardsPausedButtonTitle: String?

    func authenticateUser() async throws {
        if let authenticationError {
            throw authenticationError
        }
    }

    func showRecoverData() {}
    func showSyncWithAnotherDevice() {}
    func showRecoveryPDF() {}
    func shareRecoveryPDF() {}
    func createAccountAndStartSyncing(optionsViewModel: SyncSettingsViewModel) {}
    func confirmAndDisableSync() async -> Bool { true }
    func confirmAndDeleteAllData() async -> Bool { true }
    func confirmRemoveDevice(_ device: SyncSettingsViewModel.Device) async -> Bool { true }
    func removeDevice(_ device: SyncSettingsViewModel.Device) {}
    func updateDeviceName(_ name: String) {}
    func refreshDevices(clearDevices: Bool) {}
    func updateOptions() {}
    func launchBookmarksViewController() {}
    func launchAutofillViewController() {}
    func launchAutofillCreditCardsViewController() {}
    func showOtherPlatformLinks() {}
    func fireOtherPlatformLinksPixel(event: SyncSettingsViewModel.PlatformLinksPixelEvent, with source: SyncSettingsViewModel.PlatformLinksPixelSource) {}
    func shareLink(for url: URL, with message: String, from rect: CGRect) {}
}

private enum SyncSettingsViewModelTestsError: Error {
    case expected
}
