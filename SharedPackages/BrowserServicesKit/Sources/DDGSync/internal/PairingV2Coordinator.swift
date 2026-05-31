//
//  PairingV2Coordinator.swift
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

import Foundation
import os.log

protocol PairingV2ConfirmationDelegate: AnyObject {
    func pairingV2CoordinatorShouldAllowPeerToJoin(peerName: String?) async -> Bool
    func pairingV2CoordinatorShouldJoinPeer(peerName: String?) async -> Bool
    func pairingV2CoordinatorDidCreateSyncAccount() async
}

final class PairingV2Coordinator {

    private let syncService: DDGSyncing
    private let messageExchanger: PairingV2MessageExchanging
    private let messageCrypto: PairingV2MessageCrypto
    private let deviceName: String
    private let deviceType: String
    private let localKind: PairingV2DeviceKind
    private let flags: PairingV2RolloutFlags
    private weak var confirmationDelegate: PairingV2ConfirmationDelegate?

    private var stateMachine = PairingV2StateMachine()
    private var localKeyPair: PairingV2KeyPair?
    private var peerChannelID: String?
    private var peerPublicKey: String?
    private var lastProcessedSequence = 0
    private(set) var completedRegisteredDevices: [RegisteredDevice]?
    private(set) var pendingRecoveryKey: SyncCode.RecoveryKey?

    init(syncService: DDGSyncing,
         messageExchanger: PairingV2MessageExchanging,
         messageCrypto: PairingV2MessageCrypto = PairingV2MessageCrypto(),
         deviceName: String,
         deviceType: String,
         localKind: PairingV2DeviceKind = .ddg,
         flags: PairingV2RolloutFlags,
         confirmationDelegate: PairingV2ConfirmationDelegate? = nil) {
        self.syncService = syncService
        self.messageExchanger = messageExchanger
        self.messageCrypto = messageCrypto
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.localKind = localKind
        self.flags = flags
        self.confirmationDelegate = confirmationDelegate
    }

    var state: PairingV2State {
        stateMachine.state
    }

    func startPresenting() async throws -> PairingV2QRCodePayload {
        let keyPair = try PairingV2KeyPairFactory.makeKeyPair()
        localKeyPair = keyPair
        peerChannelID = nil
        peerPublicKey = nil
        lastProcessedSequence = 0

        let commands = stateMachine.handle(
            .presentCodeRequested(localClient: localClient(isPresenter: true), flags: flags)
        )
        try await execute(commands)

        return PairingV2QRCodePayload(channelId: keyPair.channelID, publicKey: keyPair.publicKey)
    }

    func startScanning(qrPayload: PairingV2QRCodePayload) async throws {
        let keyPair = try PairingV2KeyPairFactory.makeKeyPair()
        localKeyPair = keyPair
        peerChannelID = qrPayload.channelId
        peerPublicKey = qrPayload.publicKey
        lastProcessedSequence = 0

        let commands = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: qrPayload.channelId), localClient: localClient(isPresenter: false), flags: flags)
        )
        try await execute(commands)
    }

    func pollOnce() async throws {
        guard let channelID = localKeyPair?.channelID else {
            throw SyncError.failedToPrepareForExchange("Pairing V2 local channel is not ready")
        }

        let messages = try await messageExchanger.fetchMessages(from: channelID, after: lastProcessedSequence)
        for message in messages.sorted(by: { $0.seq < $1.seq }) {
            guard !isTerminal else {
                return
            }
            try await handle(message.encryptedMessage, sequence: message.seq)
            lastProcessedSequence = max(lastProcessedSequence, message.seq)
        }
    }

    func pollUntilFinished(timeout: TimeInterval = 300, pollInterval: UInt64 = 1_000_000_000) async throws -> PairingV2State.Completion {
        let timeoutDate = Date().addingTimeInterval(timeout)

        while true {
            switch stateMachine.state {
            case .completed(let completion):
                return completion
            case .failed(let error):
                throw error
            default:
                break
            }

            if Date() > timeoutDate {
                throw SyncError.pollingDidTimeOut
            }

            try await pollOnce()
            try await Task.sleep(nanoseconds: pollInterval)
        }
    }

    func cancel() async {
        _ = stateMachine.handle(.failed(.cancelled))
        await closeLocalChannel()
    }

    func closeLocalChannel() async {
        guard let channelID = localKeyPair?.channelID else {
            return
        }
        try? await messageExchanger.closeChannel(channelID)
    }

    private func handle(_ encryptedMessage: PairingV2EncryptedMessage, sequence: Int? = nil) async throws {
        guard let privateKey = localKeyPair?.privateKey else {
            throw SyncError.failedToPrepareForExchange("Pairing V2 private key is not ready")
        }

        guard let message = try messageCrypto.decrypt(encryptedMessage, privateKey: privateKey, expectedSenderChannelID: peerChannelID) else {
            return
        }

        let commands: [PairingV2Command]
        let stateBeforeMessage = stateMachine.state
        switch message {
        case .hello(let message):
            if shouldRejectRedundantHello(message, stateBeforeMessage: stateBeforeMessage) {
                commands = stateMachine.handle(.failed(.unexpectedEvent("redundant hello did not match scanned Pairing V2 code")))
            } else {
                commands = stateMachine.handle(.receivedHello(message))
            }
            if case .waitingForPeerHello = stateBeforeMessage, !isTerminal {
                peerChannelID = message.channelId
                peerPublicKey = message.publicKey
            }

        case .recoveryCodeAvailable(let message):
            commands = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(name: message.name, kind: message.kind, userId: message.userId)))

        case .recoveryCodeRequest(let message):
            commands = stateMachine.handle(.receivedPeerStatus(.recoveryCodeRequest(name: message.name, kind: message.kind)))

        case .recoveryCodeAwaitingConfirmation:
            commands = stateMachine.handle(.receivedRecoveryCodeAwaitingConfirmation)

        case .recoveryCodeConfirmed:
            commands = stateMachine.handle(.receivedRecoveryCodeConfirmed)

        case .recoveryCodeResponse(let message):
            let recoveryCode = recoveryCode(from: message)
            commands = stateMachine.handle(.receivedRecoveryCode(recoveryCode))

        case .recoveryCodeDenied:
            commands = stateMachine.handle(.receivedRecoveryCodeDenied)

        case .recoveryCodeUnavailable:
            commands = stateMachine.handle(.receivedRecoveryCodeUnavailable)
        }

        try await execute(commands)
    }

    private func shouldRejectRedundantHello(_ message: PairingV2HelloMessage, stateBeforeMessage: PairingV2State) -> Bool {
        guard case .waitingForPeerStatus(let session) = stateBeforeMessage,
              !session.localClient.isPresenter,
              !session.hasReceivedHello else {
            return false
        }

        return message.channelId != peerChannelID || message.publicKey != peerPublicKey
    }

    private func execute(_ commands: [PairingV2Command]) async throws {
        for command in commands {
            try await execute(command)
        }
    }

    private func execute(_ command: PairingV2Command) async throws {
        switch command {
        case .openV2Channel(let channelID):
            let channelID = try channelID ?? requiredLocalChannelID()
            try await messageExchanger.openChannel(channelID)

        case .sendHello:
            let keyPair = try requiredLocalKeyPair()
            try await send(.hello(.init(channelId: keyPair.channelID, publicKey: keyPair.publicKey)))

        case .sendRecoveryCodeStatus(let status):
            try await send(recoveryCodeStatusMessage(for: status))

        case .sendRecoveryCodeAwaitingConfirmation:
            try await send(.recoveryCodeAwaitingConfirmation(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAwaitingConfirmation)))

        case .sendRecoveryCodeConfirmed:
            try await send(.recoveryCodeConfirmed(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeConfirmed)))

        case .sendRecoveryCodeDenied:
            try await send(.recoveryCodeDenied(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeDenied)))

        case .requestHostConfirmation(let peerName):
            guard let confirmationDelegate else {
                try await execute(stateMachine.handle(.hostConfirmationDenied))
                return
            }
            let isConfirmed = await confirmationDelegate.pairingV2CoordinatorShouldAllowPeerToJoin(peerName: peerName)
            let event: PairingV2Event = isConfirmed ? .hostConfirmationAccepted : .hostConfirmationDenied
            try await execute(stateMachine.handle(event))

        case .requestJoinerConfirmation(let peerName):
            guard let confirmationDelegate else {
                try await execute(stateMachine.handle(.joinerConfirmationDenied))
                return
            }
            let isConfirmed = await confirmationDelegate.pairingV2CoordinatorShouldJoinPeer(peerName: peerName)
            let event: PairingV2Event = isConfirmed ? .joinerConfirmationAccepted : .joinerConfirmationDenied
            try await execute(stateMachine.handle(event))

        case .prepareRecoveryCode(let credentialKind, let purpose):
            let recoveryCode: String
            do {
                recoveryCode = try await prepareRecoveryCode(credentialKind: credentialKind, purpose: purpose)
            } catch {
                try await execute(stateMachine.handle(.failed(.recoveryCodePreparationFailed)))
                throw PairingV2Error.recoveryCodePreparationFailed
            }
            try await execute(stateMachine.handle(.recoveryCodePrepared(recoveryCode)))

        case .sendRecoveryCode(let recoveryCode):
            do {
                try await sendRecoveryCode(recoveryCode)
            } catch {
                try await execute(stateMachine.handle(.failed(.recoveryCodeSendFailed)))
                throw PairingV2Error.recoveryCodeSendFailed
            }
            try await execute(stateMachine.handle(.recoveryCodeSent))

        case .loginWithRecoveryCode(let recoveryCode):
            do {
                try await login(with: recoveryCode)
            } catch {
                try await execute(stateMachine.handle(.failed(.loginFailed)))
                throw PairingV2Error.loginFailed
            }
            try await execute(stateMachine.handle(.loginSucceeded))

        case .upgradeThirdPartyAccountWithRecoveryCode(let recoveryCode):
            do {
                try await upgradeThirdPartyAccount(with: recoveryCode)
            } catch let error as PairingV2Error {
                try await execute(stateMachine.handle(.failed(error)))
                throw error
            } catch {
                try await execute(stateMachine.handle(.failed(.loginFailed)))
                throw PairingV2Error.loginFailed
            }
            try await execute(stateMachine.handle(.loginSucceeded))

        case .stopPolling:
            await closeLocalChannel()

        case .abort:
            await closeLocalChannel()
        }
    }

    private func send(_ message: PairingV2ApplicationMessage) async throws {
        guard let peerChannelID, let peerPublicKey else {
            throw SyncError.failedToPrepareForExchange("Pairing V2 peer channel is not ready")
        }

        let encryptedMessage = try messageCrypto.encrypt(message, recipientPublicKey: peerPublicKey, senderChannelID: try requiredLocalChannelID())
        try await messageExchanger.send([encryptedMessage], to: peerChannelID)
    }

    private func recoveryCodeStatusMessage(for status: PairingV2PeerStatus) -> PairingV2ApplicationMessage {
        let name = status.name ?? deviceName

        if status.hasAccount {
            return .recoveryCodeAvailable(
                .init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeAvailable,
                      name: name,
                      kind: status.kind,
                      userId: status.userId ?? syncService.account?.userId))
        }
        return .recoveryCodeRequest(.init(type: PairingV2ApplicationMessage.MessageType.recoveryCodeRequest, name: name, kind: status.kind))
    }

    private func prepareRecoveryCode(credentialKind: PairingV2DeviceKind, purpose: String) async throws -> String {
        try await ensureSyncAccountExists()

        switch credentialKind {
        case .thirdParty:
            return try await syncService.prepareThirdPartyRecoveryCode(purpose: purpose)
        case .ddg:
            guard let recoveryCode = syncService.account?.recoveryCode else {
                throw SyncError.invalidRecoveryKey
            }
            return recoveryCode
        }
    }

    private func ensureSyncAccountExists() async throws {
        guard syncService.account == nil else {
            return
        }

        try await syncService.createAccount(deviceName: deviceName, deviceType: deviceType)
        await confirmationDelegate?.pairingV2CoordinatorDidCreateSyncAccount()
    }

    private func sendRecoveryCode(_ recoveryCode: String) async throws {
        let response = PairingV2ApplicationMessage.recoveryCodeResponse(
            .init(recoveryCode: recoveryCode)
        )
        try await send(response)
    }

    private func recoveryCode(from response: PairingV2RecoveryCodeResponseMessage) -> String {
        response.recoveryCode
    }

    private func login(with recoveryCode: String) async throws {
        let syncCode = try SyncCode.decodeBase64String(recoveryCode)
        guard let recovery = syncCode.recovery, let recoveryKey = recovery.legacyRecoveryKey() else {
            throw SyncError.invalidRecoveryKey
        }
        pendingRecoveryKey = recoveryKey
        completedRegisteredDevices = try await syncService.login(recoveryKey, deviceName: deviceName, deviceType: deviceType)
    }

    private func upgradeThirdPartyAccount(with recoveryCode: String) async throws {
        do {
            completedRegisteredDevices = try await syncService.upgradeThirdPartyAccountToDefaultCredential(recoveryCode,
                                                                                                           deviceName: deviceName,
                                                                                                           deviceType: deviceType)
        } catch {
            Logger.sync.error("Pairing V2 3party account upgrade failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func localClient(isPresenter: Bool) -> PairingV2LocalClient {
        PairingV2LocalClient(name: deviceName, kind: localKind, hasAccount: syncService.account != nil, isPresenter: isPresenter, userId: syncService.account?.userId)
    }

    private func requiredLocalKeyPair() throws -> PairingV2KeyPair {
        guard let localKeyPair else {
            throw SyncError.failedToPrepareForExchange("Pairing V2 local key pair is not ready")
        }
        return localKeyPair
    }

    private func requiredLocalChannelID() throws -> String {
        try requiredLocalKeyPair().channelID
    }

    private var isTerminal: Bool {
        switch stateMachine.state {
        case .completed, .failed:
            return true
        default:
            return false
        }
    }
}
