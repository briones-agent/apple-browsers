//
//  PairingV2CoordinatorTests.swift
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

import Security
import XCTest

@testable import DDGSync

private final class PairingV2ConfirmationDelegateMock: PairingV2ConfirmationDelegate {
    var shouldAllowPeerToJoin = true
    var shouldJoinPeer = true
    var allowPeerToJoinCalls: [String?] = []
    var joinPeerCalls: [String?] = []
    var didCreateSyncAccountCallCount = 0

    func pairingV2CoordinatorShouldAllowPeerToJoin(peerName: String?) async -> Bool {
        allowPeerToJoinCalls.append(peerName)
        return shouldAllowPeerToJoin
    }

    func pairingV2CoordinatorShouldJoinPeer(peerName: String?) async -> Bool {
        joinPeerCalls.append(peerName)
        return shouldJoinPeer
    }

    func pairingV2CoordinatorDidCreateSyncAccount() async {
        didCreateSyncAccountCallCount += 1
    }
}

final class PairingV2CoordinatorTests: XCTestCase {

    func testWhenStartPresentingThenOpensLocalChannelAndReturnsQRCodePayload() async throws {
        let dependencies = MockSyncDependencies()
        let syncService = DDGSync(dataProvidersSource: MockDataProvidersSource(), dependencies: dependencies)
        let messageExchanger = PairingV2MessageExchangingMock()
        let coordinator = makeCoordinator(syncService: syncService, messageExchanger: messageExchanger)

        let payload = try await coordinator.startPresenting()

        XCTAssertEqual(payload.version, PairingV2ProtocolVersion.current)
        XCTAssertFalse(payload.channelId.isEmpty)
        XCTAssertFalse(payload.publicKey.isEmpty)
        XCTAssertEqual(messageExchanger.openChannelCalls, [payload.channelId])
        XCTAssertEqual(
            coordinator.state,
            .waitingForPeerHello(.init(localClient: .init(name: "Mac", kind: .ddg, hasAccount: false, isPresenter: true), channelID: nil))
        )
    }

    func testWhenPresenterReceivesHelloThenSendsRecoveryCodeStatusToPeerChannel() async throws {
        let dependencies = MockSyncDependencies()
        let syncService = DDGSync(dataProvidersSource: MockDataProvidersSource(), dependencies: dependencies)
        let messageExchanger = PairingV2MessageExchangingMock()
        let messageCrypto = PairingV2MessageCrypto()
        let peerKeyPair = try PairingV2KeyPairFactory.makeKeyPair(channelID: "peer-channel")
        let coordinator = makeCoordinator(syncService: syncService, messageExchanger: messageExchanger, messageCrypto: messageCrypto)

        let payload = try await coordinator.startPresenting()
        messageExchanger.fetchMessagesStub = try encryptedPeerMessages(
            [
                .hello(.init(channelId: peerKeyPair.channelID, publicKey: peerKeyPair.publicKey))
            ],
            recipientPublicKey: payload.publicKey,
            peerKeyPair: peerKeyPair,
            messageCrypto: messageCrypto
        )

        try await coordinator.pollOnce()

        XCTAssertEqual(messageExchanger.fetchMessagesCalls.map(\.channelID), [payload.channelId])
        XCTAssertEqual(messageExchanger.sendCalls.map(\.channelID), [peerKeyPair.channelID])
        XCTAssertEqual(
            try decryptSentMessage(at: 0, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeRequest(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeRequest, name: "Mac", kind: .ddg))
        )
        XCTAssertEqual(
            coordinator.state,
            .waitingForPeerStatus(.init(localClient: .init(name: "Mac", kind: .ddg, hasAccount: false, isPresenter: true), channelID: nil))
        )
    }

    func testWhenPresenterHostsNativePeerThenSendsProgressMessagesBeforeRecoveryCodeResponse() async throws {
        let dependencies = MockSyncDependencies()
        try dependencies.secureStore.persistAccount(SyncAccount.mock)
        let syncService = DDGSync(dataProvidersSource: MockDataProvidersSource(), dependencies: dependencies)
        let messageExchanger = PairingV2MessageExchangingMock()
        let messageCrypto = PairingV2MessageCrypto()
        let peerKeyPair = try PairingV2KeyPairFactory.makeKeyPair(channelID: "peer-channel")
        let confirmationDelegate = PairingV2ConfirmationDelegateMock()
        let coordinator = makeCoordinator(syncService: syncService,
                                          messageExchanger: messageExchanger,
                                          messageCrypto: messageCrypto,
                                          confirmationDelegate: confirmationDelegate)

        let payload = try await coordinator.startPresenting()
        messageExchanger.fetchMessagesStub = try encryptedPeerMessages(
            [
                .hello(.init(channelId: peerKeyPair.channelID, publicKey: peerKeyPair.publicKey)),
                .recoveryCodeAvailable(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAvailable,
                                             name: "Peer",
                                             kind: .ddg,
                                             userId: "peer-user"))
            ],
            recipientPublicKey: payload.publicKey,
            peerKeyPair: peerKeyPair,
            messageCrypto: messageCrypto
        )

        try await coordinator.pollOnce()

        let recoveryCode = try XCTUnwrap(syncService.account?.recoveryCode)
        XCTAssertEqual(confirmationDelegate.allowPeerToJoinCalls, ["Peer"])
        XCTAssertEqual(messageExchanger.sendCalls.map(\.channelID), [
            peerKeyPair.channelID,
            peerKeyPair.channelID,
            peerKeyPair.channelID,
            peerKeyPair.channelID
        ])
        XCTAssertEqual(
            try decryptSentMessage(at: 0, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeAvailable(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAvailable,
                                         name: "Mac",
                                         kind: .ddg,
                                         userId: SyncAccount.mock.userId))
        )
        XCTAssertEqual(
            try decryptSentMessage(at: 1, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeAwaitingConfirmation(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAwaitingConfirmation))
        )
        XCTAssertEqual(
            try decryptSentMessage(at: 2, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeConfirmed(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeConfirmed))
        )
        XCTAssertEqual(
            try decryptSentMessage(at: 3, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeResponse(.init(recoveryCode: recoveryCode))
        )
        XCTAssertEqual(coordinator.state, .completed(.recoveryCodeSent))
    }

    func testWhenNoAccountPresenterHostsNativePeerThenCreatesAccountBeforeSendingRecoveryCodeResponse() async throws {
        let dependencies = MockSyncDependencies()
        let accountManager = AccountManagingMock()
        dependencies.account = accountManager
        let syncService = DDGSync(dataProvidersSource: MockDataProvidersSource(), dependencies: dependencies)
        let messageExchanger = PairingV2MessageExchangingMock()
        let messageCrypto = PairingV2MessageCrypto()
        let peerKeyPair = try PairingV2KeyPairFactory.makeKeyPair(channelID: "peer-channel")
        let confirmationDelegate = PairingV2ConfirmationDelegateMock()
        let coordinator = makeCoordinator(syncService: syncService,
                                          messageExchanger: messageExchanger,
                                          messageCrypto: messageCrypto,
                                          confirmationDelegate: confirmationDelegate)

        let payload = try await coordinator.startPresenting()
        messageExchanger.fetchMessagesStub = try encryptedPeerMessages(
            [
                .hello(.init(channelId: peerKeyPair.channelID, publicKey: peerKeyPair.publicKey)),
                .recoveryCodeRequest(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeRequest,
                                           name: "Peer",
                                           kind: .ddg))
            ],
            recipientPublicKey: payload.publicKey,
            peerKeyPair: peerKeyPair,
            messageCrypto: messageCrypto
        )

        try await coordinator.pollOnce()

        let recoveryCode = try XCTUnwrap(syncService.account?.recoveryCode)
        XCTAssertEqual(accountManager.createAccountCalls.map(\.deviceName), ["Mac"])
        XCTAssertEqual(accountManager.createAccountCalls.map(\.deviceType), ["desktop"])
        XCTAssertEqual(confirmationDelegate.didCreateSyncAccountCallCount, 1)
        XCTAssertEqual(
            try decryptSentMessage(at: 0, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeRequest(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeRequest, name: "Mac", kind: .ddg))
        )
        XCTAssertEqual(
            try decryptSentMessage(at: 1, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeAwaitingConfirmation(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAwaitingConfirmation))
        )
        XCTAssertEqual(
            try decryptSentMessage(at: 2, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeConfirmed(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeConfirmed))
        )
        XCTAssertEqual(
            try decryptSentMessage(at: 3, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeResponse(.init(recoveryCode: recoveryCode))
        )
        XCTAssertEqual(coordinator.state, .completed(.recoveryCodeSent))
    }

    func testWhenPresenterHostConfirmationIsDeniedThenSendsRecoveryCodeDeniedAndStops() async throws {
        let dependencies = MockSyncDependencies()
        try dependencies.secureStore.persistAccount(SyncAccount.mock)
        let syncService = DDGSync(dataProvidersSource: MockDataProvidersSource(), dependencies: dependencies)
        let messageExchanger = PairingV2MessageExchangingMock()
        let messageCrypto = PairingV2MessageCrypto()
        let peerKeyPair = try PairingV2KeyPairFactory.makeKeyPair(channelID: "peer-channel")
        let confirmationDelegate = PairingV2ConfirmationDelegateMock()
        confirmationDelegate.shouldAllowPeerToJoin = false
        let coordinator = makeCoordinator(syncService: syncService,
                                          messageExchanger: messageExchanger,
                                          messageCrypto: messageCrypto,
                                          confirmationDelegate: confirmationDelegate)

        let payload = try await coordinator.startPresenting()
        messageExchanger.fetchMessagesStub = try encryptedPeerMessages(
            [
                .hello(.init(channelId: peerKeyPair.channelID, publicKey: peerKeyPair.publicKey)),
                .recoveryCodeRequest(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeRequest,
                                           name: "Peer",
                                           kind: .ddg))
            ],
            recipientPublicKey: payload.publicKey,
            peerKeyPair: peerKeyPair,
            messageCrypto: messageCrypto
        )

        try await coordinator.pollOnce()

        XCTAssertEqual(confirmationDelegate.allowPeerToJoinCalls, ["Peer"])
        XCTAssertEqual(
            try decryptSentMessage(at: 2, from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto),
            .recoveryCodeDenied(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeDenied))
        )
        XCTAssertEqual(coordinator.state, .failed(.cancelled))
        XCTAssertEqual(messageExchanger.closeChannelCalls, [payload.channelId])
    }

    func testWhenNativeJoinerReceivesThirdPartyRecoveryCodeThenDelegatesUpgradeToSyncService() async throws {
        let dependencies = MockSyncDependencies()
        let upgradeCoordinator = ThirdPartyAccountUpgradeCoordinatingMock()
        dependencies.createThirdPartyAccountUpgradeCoordinatorStub = upgradeCoordinator
        (dependencies.secureStore as? SecureStorageStub)?.theAccount = nil

        let syncService = DDGSync(dataProvidersSource: MockDataProvidersSource(), dependencies: dependencies)
        let messageExchanger = PairingV2MessageExchangingMock()
        let messageCrypto = PairingV2MessageCrypto()
        let peerKeyPair = try PairingV2KeyPairFactory.makeKeyPair(channelID: "peer-channel")
        let confirmationDelegate = PairingV2ConfirmationDelegateMock()
        let coordinator = PairingV2Coordinator(syncService: syncService,
                                               messageExchanger: messageExchanger,
                                               messageCrypto: messageCrypto,
                                               deviceName: "Mac",
                                               deviceType: "desktop",
                                               flags: PairingV2RolloutFlags(isV2ScanningEnabled: true, isV2CodeEnabled: true),
                                               confirmationDelegate: confirmationDelegate)

        try await coordinator.startScanning(qrPayload: .init(channelId: peerKeyPair.channelID, publicKey: peerKeyPair.publicKey))
        let hello = try localHello(from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto)

        messageExchanger.fetchMessagesStub = [
            .init(seq: 1,
                  version: PairingV2ProtocolVersion.current,
                  payload: try messageCrypto.encrypt(
                    .recoveryCodeAvailable(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAvailable,
                                                 name: "Peer",
                                                 kind: .thirdParty,
                                                 userId: "third-party-user")),
                    recipientPublicKey: hello.publicKey,
                    senderChannelID: peerKeyPair.channelID).payload)
        ]
        try await coordinator.pollOnce()
        XCTAssertEqual(confirmationDelegate.joinPeerCalls, ["Peer"])
        XCTAssertEqual(
            coordinator.state,
            .joinerWaitingForRecoveryCode(
                .init(localClient: .init(name: "Mac", kind: .ddg, hasAccount: false, isPresenter: false),
                      channelID: peerKeyPair.channelID,
                      peerStatus: .recoveryCodeAvailable(name: "Peer", kind: .thirdParty, userId: "third-party-user"))
            )
        )

        let recoveryCode = "third-party-recovery-code"
        messageExchanger.fetchMessagesStub = [
            .init(seq: 2,
                  version: PairingV2ProtocolVersion.current,
                  payload: try messageCrypto.encrypt(
                    .recoveryCodeResponse(.init(recoveryCode: recoveryCode)),
                    recipientPublicKey: hello.publicKey,
                    senderChannelID: peerKeyPair.channelID).payload)
        ]
        try await coordinator.pollOnce()

        XCTAssertEqual(upgradeCoordinator.upgradeThirdPartyAccountCalls.map(\.recoveryCode), [recoveryCode])
        XCTAssertEqual(upgradeCoordinator.upgradeThirdPartyAccountCalls.first?.deviceName, "Mac")
        XCTAssertEqual(upgradeCoordinator.upgradeThirdPartyAccountCalls.first?.deviceType, "desktop")
        XCTAssertEqual(coordinator.completedRegisteredDevices?.map(\.id), [RegisteredDevice.mock.id])
        XCTAssertEqual(coordinator.completedRegisteredDevices?.map(\.name), [RegisteredDevice.mock.name])
        XCTAssertEqual(coordinator.completedRegisteredDevices?.map(\.type), [RegisteredDevice.mock.type])
        XCTAssertEqual(coordinator.state, .completed(.loggedIn))
        XCTAssertEqual((dependencies.secureStore as? SecureStorageStub)?.theAccount?.userId, SyncAccount.mock.userId)
        XCTAssertEqual((dependencies.secureStore as? SecureStorageStub)?.theScopedPassword, Data(repeating: 1, count: 32))
    }

    func testWhenNativeJoinerConfirmationIsDeniedThenDoesNotLoginIfRecoveryCodeArrives() async throws {
        let dependencies = MockSyncDependencies()
        let upgradeCoordinator = ThirdPartyAccountUpgradeCoordinatingMock()
        dependencies.createThirdPartyAccountUpgradeCoordinatorStub = upgradeCoordinator
        (dependencies.secureStore as? SecureStorageStub)?.theAccount = nil

        let syncService = DDGSync(dataProvidersSource: MockDataProvidersSource(), dependencies: dependencies)
        let messageExchanger = PairingV2MessageExchangingMock()
        let messageCrypto = PairingV2MessageCrypto()
        let peerKeyPair = try PairingV2KeyPairFactory.makeKeyPair(channelID: "peer-channel")
        let confirmationDelegate = PairingV2ConfirmationDelegateMock()
        confirmationDelegate.shouldJoinPeer = false
        let coordinator = PairingV2Coordinator(syncService: syncService,
                                               messageExchanger: messageExchanger,
                                               messageCrypto: messageCrypto,
                                               deviceName: "Mac",
                                               deviceType: "desktop",
                                               flags: PairingV2RolloutFlags(isV2ScanningEnabled: true, isV2CodeEnabled: true),
                                               confirmationDelegate: confirmationDelegate)

        try await coordinator.startScanning(qrPayload: .init(channelId: peerKeyPair.channelID, publicKey: peerKeyPair.publicKey))
        let hello = try localHello(from: messageExchanger, peerPrivateKey: peerKeyPair.privateKey, messageCrypto: messageCrypto)

        messageExchanger.fetchMessagesStub = [
            .init(seq: 1,
                  version: PairingV2ProtocolVersion.current,
                  payload: try messageCrypto.encrypt(
                    .recoveryCodeAvailable(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAvailable,
                                                 name: "Peer",
                                                 kind: .thirdParty,
                                                 userId: "third-party-user")),
                    recipientPublicKey: hello.publicKey,
                    senderChannelID: peerKeyPair.channelID).payload)
        ]
        try await coordinator.pollOnce()

        messageExchanger.fetchMessagesStub = [
            .init(seq: 2,
                  version: PairingV2ProtocolVersion.current,
                  payload: try messageCrypto.encrypt(
                    .recoveryCodeResponse(.init(recoveryCode: "third-party-recovery-code")),
                    recipientPublicKey: hello.publicKey,
                    senderChannelID: peerKeyPair.channelID).payload)
        ]
        try await coordinator.pollOnce()

        XCTAssertEqual(confirmationDelegate.joinPeerCalls, ["Peer"])
        XCTAssertTrue(upgradeCoordinator.upgradeThirdPartyAccountCalls.isEmpty)
        XCTAssertNil(coordinator.completedRegisteredDevices)
        XCTAssertEqual(coordinator.state, .failed(.cancelled))
        XCTAssertEqual(messageExchanger.closeChannelCalls.count, 1)
    }

    private func makeCoordinator(syncService: DDGSyncing,
                                 messageExchanger: PairingV2MessageExchanging,
                                 messageCrypto: PairingV2MessageCrypto = PairingV2MessageCrypto(),
                                 confirmationDelegate: PairingV2ConfirmationDelegate? = nil) -> PairingV2Coordinator {
        PairingV2Coordinator(syncService: syncService,
                             messageExchanger: messageExchanger,
                             messageCrypto: messageCrypto,
                             deviceName: "Mac",
                             deviceType: "desktop",
                             flags: PairingV2RolloutFlags(isV2ScanningEnabled: true, isV2CodeEnabled: true),
                             confirmationDelegate: confirmationDelegate)
    }

    private func encryptedPeerMessages(_ messages: [PairingV2ApplicationMessage],
                                       recipientPublicKey: String,
                                       peerKeyPair: PairingV2KeyPair,
                                       messageCrypto: PairingV2MessageCrypto) throws -> [PairingV2SequencedMessage] {
        try messages.enumerated().map { index, message in
            let encryptedMessage = try messageCrypto.encrypt(message, recipientPublicKey: recipientPublicKey, senderChannelID: peerKeyPair.channelID)
            return PairingV2SequencedMessage(seq: index + 1, version: encryptedMessage.version, payload: encryptedMessage.payload)
        }
    }

    private func decryptSentMessage(at index: Int,
                                    from messageExchanger: PairingV2MessageExchangingMock,
                                    peerPrivateKey: SecKey,
                                    messageCrypto: PairingV2MessageCrypto,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> PairingV2ApplicationMessage {
        let optionalSendCall: (messages: [PairingV2EncryptedMessage], channelID: String)?
        if messageExchanger.sendCalls.indices.contains(index) {
            optionalSendCall = messageExchanger.sendCalls[index]
        } else {
            optionalSendCall = nil
        }
        let sendCall = try XCTUnwrap(optionalSendCall, file: file, line: line)
        let encryptedMessage = try XCTUnwrap(sendCall.messages.first, file: file, line: line)
        return try XCTUnwrap(try messageCrypto.decrypt(encryptedMessage, privateKey: peerPrivateKey), file: file, line: line)
    }

    private func localHello(from messageExchanger: PairingV2MessageExchangingMock,
                            peerPrivateKey: SecKey,
                            messageCrypto: PairingV2MessageCrypto) throws -> PairingV2HelloMessage {
        let encryptedHello = try XCTUnwrap(messageExchanger.sendCalls.first?.messages.first)
        let message = try XCTUnwrap(try messageCrypto.decrypt(encryptedHello, privateKey: peerPrivateKey))
        guard case .hello(let hello) = message else {
            XCTFail("Expected local hello")
            throw PairingV2Error.unexpectedEvent("Expected local hello")
        }
        return hello
    }
}
