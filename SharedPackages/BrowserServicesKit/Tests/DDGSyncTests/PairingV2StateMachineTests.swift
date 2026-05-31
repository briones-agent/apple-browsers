//
//  PairingV2StateMachineTests.swift
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

@testable import DDGSync

final class PairingV2StateMachineTests: XCTestCase {

    func testWhenLocalHasAccountAndPeerDoesNotThenLocalBecomesHostBeforeKindRules() {
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        let decision = PairingV2RoleElection.decideRole(
            localClient: localClient,
            peerStatus: .recoveryCodeRequest(kind: .thirdParty)
        )

        XCTAssertEqual(decision, .host(joinerKind: .thirdParty))
    }

    func testWhenPeerHasAccountAndLocalDoesNotThenLocalBecomesJoinerBeforeKindRules() {
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        let decision = PairingV2RoleElection.decideRole(
            localClient: localClient,
            peerStatus: .recoveryCodeAvailable(kind: .thirdParty)
        )

        XCTAssertEqual(decision, .joiner(hostKind: .thirdParty))
    }

    func testWhenAccountsMatchAndLocalIsDDGWithThirdPartyPeerThenLocalBecomesHost() {
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        let decision = PairingV2RoleElection.decideRole(
            localClient: localClient,
            peerStatus: .recoveryCodeRequest(kind: .thirdParty)
        )

        XCTAssertEqual(decision, .host(joinerKind: .thirdParty))
    }

    func testWhenAccountAndKindRulesDoNotDecideThenPresenterBecomesHost() {
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: true)

        let decision = PairingV2RoleElection.decideRole(
            localClient: localClient,
            peerStatus: .recoveryCodeAvailable(kind: .ddg)
        )

        XCTAssertEqual(decision, .host(joinerKind: .ddg))
    }

    func testWhenScannerReceivedHelloAndLocalChannelIDIsLowerThenLocalBecomesHost() {
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        let decision = PairingV2RoleElection.decideRole(
            localClient: localClient,
            peerStatus: .recoveryCodeRequest(kind: .ddg),
            localChannelID: "channel-a",
            peerChannelID: "channel-b"
        )

        XCTAssertEqual(decision, .host(joinerKind: .ddg))
    }

    func testWhenScannerReceivedHelloAndLocalChannelIDIsHigherThenLocalBecomesJoiner() {
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        let decision = PairingV2RoleElection.decideRole(
            localClient: localClient,
            peerStatus: .recoveryCodeRequest(kind: .ddg),
            localChannelID: "channel-b",
            peerChannelID: "channel-a"
        )

        XCTAssertEqual(decision, .joiner(hostKind: .ddg))
    }

    func testWhenScannerHasNoEarlierRuleAndNoPeerHelloThenLocalBecomesJoiner() {
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        let decision = PairingV2RoleElection.decideRole(
            localClient: localClient,
            peerStatus: .recoveryCodeRequest(kind: .ddg)
        )

        XCTAssertEqual(decision, .joiner(hostKind: .ddg))
    }

    func testWhenNativeAccountScannerScansV2LinkingCodeThenSendsHelloAndAccountStatus() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(name: "Scanner", kind: .ddg, hasAccount: true, isPresenter: false)

        let commands = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )

        XCTAssertEqual(commands, [
            .openV2Channel(channelID: nil),
            .sendHello,
            .sendRecoveryCodeStatus(.recoveryCodeAvailable(name: "Scanner", kind: .ddg))
        ])
        XCTAssertEqual(
            stateMachine.state,
            .waitingForPeerStatus(.init(localClient: localClient, peerChannelID: "channel-1"))
        )
    }

    func testWhenPresenterFlowIsRequestedThenOpensLocalChannelAndWaitsForHello() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: true)

        let commands = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: enabledFlags))

        XCTAssertEqual(commands, [.openV2Channel(channelID: nil)])
        XCTAssertEqual(stateMachine.state, .waitingForPeerHello(.init(localClient: localClient, peerChannelID: nil)))
    }

    func testWhenPresenterFlowIsRequestedWithCodeDisabledThenFlowAborts() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: true)
        let flags = PairingV2RolloutFlags(isV2ScanningEnabled: true, isV2CodeEnabled: false)
        let error = PairingV2Error.unsupportedFlow("Pairing V2 code presentation is disabled")

        let commands = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: flags))

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    func testWhenPresenterReceivesHelloThenSendsLocalRecoveryCodeStatus() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(name: "Presenter", kind: .ddg, hasAccount: true, isPresenter: true, userId: "local-user")

        _ = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: enabledFlags))
        let commands = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))

        XCTAssertEqual(commands, [
            .sendRecoveryCodeStatus(.recoveryCodeAvailable(name: "Presenter", kind: .ddg, userId: "local-user"))
        ])
        XCTAssertEqual(stateMachine.state, .waitingForPeerStatus(.init(localClient: localClient, peerChannelID: nil)))
    }

    func testWhenNativeWithoutAccountScansV2LinkingCodeThenSendsHelloAndRecoveryCodeRequest() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        let commands = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )

        XCTAssertEqual(commands, [
            .openV2Channel(channelID: nil),
            .sendHello,
            .sendRecoveryCodeStatus(.recoveryCodeRequest(kind: .ddg))
        ])
        XCTAssertEqual(
            stateMachine.state,
            .waitingForPeerStatus(.init(localClient: localClient, peerChannelID: "channel-1"))
        )
    }

    func testWhenScannerReceivesHelloAfterSendingHelloThenAbsorbsSimultaneousScanHello() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        let commands = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))

        XCTAssertEqual(commands, [])
        XCTAssertEqual(
            stateMachine.state,
            .waitingForPeerStatus(.init(localClient: localClient, peerChannelID: "channel-1", hasReceivedHello: true))
        )
    }

    func testWhenScannerReceivesSecondHelloAfterAbsorbingSimultaneousScanHelloThenFlowAborts() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)
        let error = PairingV2Error.unexpectedEvent("hello received after peer hello was already established")

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        _ = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))
        let commands = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    func testWhenPresenterReceivesSecondHelloThenFlowAborts() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: true)
        let error = PairingV2Error.unexpectedEvent("hello received after peer hello was already established")

        _ = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))
        let commands = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    func testWhenHelloArrivesAfterPeerStatusThenFlowAborts() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)
        let error = PairingV2Error.unexpectedEvent("hello received after peer status was already established")

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .ddg)))
        let commands = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    func testWhenHelloHasUnsupportedVersionThenFlowAborts() {
        var stateMachine = PairingV2StateMachine()
        let commands = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key", version: "3.0")))

        XCTAssertEqual(commands, [.abort(.unsupportedVersion("3.0"))])
        XCTAssertEqual(stateMachine.state, .failed(.unsupportedVersion("3.0")))
    }

    func testWhenNativeScansThirdPartyRecoveryCodeThenFlowAbortsAsIncompatible() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        let commands = stateMachine.handle(
            .scannedCode(.recoveryCode(kind: .thirdParty, code: "recovery-code"), localClient: localClient, flags: enabledFlags)
        )

        XCTAssertEqual(commands, [
            .abort(.incompatibleRecoveryCode(scanningKind: .ddg, codeKind: .thirdParty))
        ])
        XCTAssertEqual(stateMachine.state, .failed(.incompatibleRecoveryCode(scanningKind: .ddg, codeKind: .thirdParty)))
    }

    func testWhenNativeHostReceivesThirdPartyAvailableThenItRequestsHostConfirmation() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        let peerStatus = PairingV2PeerStatus.recoveryCodeAvailable(name: "Peer", kind: .thirdParty)
        let commands = stateMachine.handle(.receivedPeerStatus(peerStatus))

        XCTAssertEqual(commands, [
            .sendRecoveryCodeAwaitingConfirmation,
            .requestHostConfirmation(peerName: "Peer")
        ])
        XCTAssertEqual(
            stateMachine.state,
            .hostWaitingForConfirmation(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: peerStatus),
                credentialKind: .thirdParty
            )
        )
    }

    func testWhenNativePresenterHostsNativePeerThenItRequestsHostConfirmation() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: true, userId: "local-user")

        _ = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))
        let peerStatus = PairingV2PeerStatus.recoveryCodeAvailable(kind: .ddg, userId: "peer-user")
        let commands = stateMachine.handle(.receivedPeerStatus(peerStatus))

        XCTAssertEqual(commands, [
            .sendRecoveryCodeAwaitingConfirmation,
            .requestHostConfirmation(peerName: nil)
        ])
        XCTAssertEqual(
            stateMachine.state,
            .hostWaitingForConfirmation(
                .init(localClient: localClient, peerChannelID: nil, peerStatus: peerStatus),
                credentialKind: .ddg
            )
        )
    }

    func testWhenNativePresenterWithoutAccountReceivesNativeRequestThenItRequestsHostConfirmation() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: true)

        _ = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))
        let peerStatus = PairingV2PeerStatus.recoveryCodeRequest(kind: .ddg)
        let commands = stateMachine.handle(.receivedPeerStatus(peerStatus))

        XCTAssertEqual(commands, [
            .sendRecoveryCodeAwaitingConfirmation,
            .requestHostConfirmation(peerName: nil)
        ])
        XCTAssertEqual(
            stateMachine.state,
            .hostWaitingForConfirmation(
                .init(localClient: localClient, peerChannelID: nil, peerStatus: peerStatus),
                credentialKind: .ddg
            )
        )
    }

    func testWhenNativeScannerWithoutAccountReceivesNativeRequestThenItRequestsJoinerConfirmation() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        let peerStatus = PairingV2PeerStatus.recoveryCodeRequest(kind: .ddg)
        let commands = stateMachine.handle(.receivedPeerStatus(peerStatus))

        XCTAssertEqual(commands, [.requestJoinerConfirmation(peerName: nil)])
        XCTAssertEqual(
            stateMachine.state,
            .joinerWaitingForConfirmation(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: peerStatus)
            )
        )
    }

    func testWhenHostConfirmationIsAcceptedThenItPreparesRecoveryCode() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(.scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeRequest(kind: .ddg)))
        let commands = stateMachine.handle(.hostConfirmationAccepted)

        XCTAssertEqual(commands, [.prepareRecoveryCode(credentialKind: .ddg, purpose: "ai_chats")])
        XCTAssertEqual(
            stateMachine.state,
            .hostPreparingRecoveryCode(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: .recoveryCodeRequest(kind: .ddg)),
                credentialKind: .ddg
            )
        )
    }

    func testWhenHostConfirmationIsDeniedThenItSendsDeniedAndAborts() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(.scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeRequest(kind: .ddg)))
        let commands = stateMachine.handle(.hostConfirmationDenied)

        XCTAssertEqual(commands, [.sendRecoveryCodeDenied, .abort(.cancelled)])
        XCTAssertEqual(stateMachine.state, .failed(.cancelled))
    }

    func testWhenPeerAvailableHasSameUserIdAsLocalAccountThenFlowCompletesAlreadyConnected() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false, userId: "same-user")

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        let commands = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .thirdParty, userId: "same-user")))

        XCTAssertEqual(commands, [.stopPolling])
        XCTAssertEqual(stateMachine.state, .completed(.alreadyConnected))
    }

    func testWhenPresenterReceivesPeerAvailableWithSameUserIdAsLocalAccountThenFlowCompletesAlreadyConnected() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: true, userId: "same-user")

        _ = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedHello(.init(channelId: "peer-channel", publicKey: "public-key")))
        let commands = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .ddg, userId: "same-user")))

        XCTAssertEqual(commands, [.stopPolling])
        XCTAssertEqual(stateMachine.state, .completed(.alreadyConnected))
    }

    func testWhenNativeAccountScannerScansNativePresenterThenRequestsJoinerConfirmation() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        let commands = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .ddg)))

        XCTAssertEqual(commands, [.requestJoinerConfirmation(peerName: nil)])
        XCTAssertEqual(
            stateMachine.state,
            .joinerWaitingForConfirmation(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: .recoveryCodeAvailable(kind: .ddg))
            )
        )
    }

    func testWhenJoinerConfirmationIsAcceptedThenItWaitsForRecoveryCode() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(.scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .ddg)))
        let commands = stateMachine.handle(.joinerConfirmationAccepted)

        XCTAssertEqual(commands, [])
        XCTAssertEqual(
            stateMachine.state,
            .joinerWaitingForRecoveryCode(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: .recoveryCodeAvailable(kind: .ddg))
            )
        )
    }

    func testWhenJoinerConfirmationIsDeniedThenItAbortsWithoutPeerMessage() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(.scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .ddg)))
        let commands = stateMachine.handle(.joinerConfirmationDenied)

        XCTAssertEqual(commands, [.abort(.cancelled)])
        XCTAssertEqual(stateMachine.state, .failed(.cancelled))
    }

    func testWhenNativeJoinerReceivesRecoveryCodeThenLogsIn() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .ddg)))
        _ = stateMachine.handle(.joinerConfirmationAccepted)
        let commands = stateMachine.handle(.receivedRecoveryCode("recovery-code"))

        XCTAssertEqual(commands, [.loginWithRecoveryCode("recovery-code")])
        XCTAssertEqual(
            stateMachine.state,
            .joinerLoggingIn(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: .recoveryCodeAvailable(kind: .ddg)),
                recoveryCode: "recovery-code"
            )
        )
    }

    func testWhenNativeJoinerReceivesHostConfirmationProgressThenItKeepsWaiting() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .thirdParty)))
        _ = stateMachine.handle(.joinerConfirmationAccepted)
        let awaitingConfirmationCommands = stateMachine.handle(.receivedRecoveryCodeAwaitingConfirmation)
        let confirmedCommands = stateMachine.handle(.receivedRecoveryCodeConfirmed)

        XCTAssertEqual(awaitingConfirmationCommands, [])
        XCTAssertEqual(confirmedCommands, [])
        XCTAssertEqual(
            stateMachine.state,
            .joinerWaitingForRecoveryCode(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: .recoveryCodeAvailable(kind: .thirdParty))
            )
        )
    }

    func testWhenConfirmationProgressArrivesBeforeJoinerIsWaitingThenFlowAborts() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        let error = PairingV2Error.unexpectedEvent("recovery_code_confirmed received while not joining")
        let commands = stateMachine.handle(.receivedRecoveryCodeConfirmed)

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    func testWhenNativeJoinerReceivesRecoveryCodeDeniedThenFlowAborts() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .thirdParty)))
        _ = stateMachine.handle(.joinerConfirmationAccepted)
        let commands = stateMachine.handle(.receivedRecoveryCodeDenied)

        XCTAssertEqual(commands, [.abort(.recoveryCodeDenied)])
        XCTAssertEqual(stateMachine.state, .failed(.recoveryCodeDenied))
    }

    func testWhenRecoveryCodeDeniedArrivesBeforeJoinerIsWaitingThenFlowAbortsAsUnexpected() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        let error = PairingV2Error.unexpectedEvent("recovery_code_denied received while not joining")
        let commands = stateMachine.handle(.receivedRecoveryCodeDenied)

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    func testWhenNativeJoinerReceivesThirdPartyRecoveryCodeThenUpgradesThirdPartyAccount() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: false, isPresenter: false)

        _ = stateMachine.handle(
            .scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags)
        )
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeAvailable(kind: .thirdParty)))
        _ = stateMachine.handle(.joinerConfirmationAccepted)
        let commands = stateMachine.handle(.receivedRecoveryCode("recovery-code"))

        XCTAssertEqual(commands, [.upgradeThirdPartyAccountWithRecoveryCode("recovery-code")])
        XCTAssertEqual(
            stateMachine.state,
            .joinerLoggingIn(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: .recoveryCodeAvailable(kind: .thirdParty)),
                recoveryCode: "recovery-code"
            )
        )
    }

    func testWhenRecoveryCodeSentFromSendingStateThenCompletesAndStopsPolling() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(.scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeRequest(kind: .thirdParty)))
        _ = stateMachine.handle(.hostConfirmationAccepted)
        _ = stateMachine.handle(.recoveryCodePrepared("recovery-code"))
        let commands = stateMachine.handle(.recoveryCodeSent)

        XCTAssertEqual(commands, [.stopPolling])
        XCTAssertEqual(stateMachine.state, .completed(.recoveryCodeSent))
    }

    func testWhenRecoveryCodeIsPreparedThenHostSendsConfirmedBeforeResponse() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)

        _ = stateMachine.handle(.scannedCode(.v2Linking(peerChannelID: "channel-1"), localClient: localClient, flags: enabledFlags))
        _ = stateMachine.handle(.receivedPeerStatus(.recoveryCodeRequest(kind: .thirdParty)))
        _ = stateMachine.handle(.hostConfirmationAccepted)
        let commands = stateMachine.handle(.recoveryCodePrepared("recovery-code"))

        XCTAssertEqual(commands, [.sendRecoveryCodeConfirmed, .sendRecoveryCode("recovery-code")])
        XCTAssertEqual(
            stateMachine.state,
            .hostSendingRecoveryCode(
                .init(localClient: localClient, peerChannelID: "channel-1", peerStatus: .recoveryCodeRequest(kind: .thirdParty)),
                recoveryCode: "recovery-code"
            )
        )
    }

    func testWhenKnownRecoveryCodeMessageArrivesWhilePresenterWaitsForHelloThenFlowAbortsAsUnexpected() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: true)

        _ = stateMachine.handle(.presentCodeRequested(localClient: localClient, flags: enabledFlags))
        let error = PairingV2Error.unexpectedEvent("recovery code received while not joining")
        let commands = stateMachine.handle(.receivedRecoveryCode("recovery-code"))

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    func testWhenCompatibleRecoveryCodeIsScannedThenFlowAbortsAsUnsupported() {
        var stateMachine = PairingV2StateMachine()
        let localClient = makeLocalClient(kind: .ddg, hasAccount: true, isPresenter: false)
        let error = PairingV2Error.unsupportedFlow("Pairing V2 recovery-code scanning is not implemented")

        let commands = stateMachine.handle(
            .scannedCode(.recoveryCode(kind: .ddg, code: "recovery-code"), localClient: localClient, flags: enabledFlags)
        )

        XCTAssertEqual(commands, [.abort(error)])
        XCTAssertEqual(stateMachine.state, .failed(error))
    }

    private var enabledFlags: PairingV2RolloutFlags {
        PairingV2RolloutFlags(isV2ScanningEnabled: true, isV2CodeEnabled: true)
    }

    private func makeLocalClient(name: String? = nil,
                                 kind: PairingV2DeviceKind,
                                 hasAccount: Bool,
                                 isPresenter: Bool,
                                 userId: String? = nil) -> PairingV2LocalClient {
        PairingV2LocalClient(name: name, kind: kind, hasAccount: hasAccount, isPresenter: isPresenter, userId: userId)
    }
}
