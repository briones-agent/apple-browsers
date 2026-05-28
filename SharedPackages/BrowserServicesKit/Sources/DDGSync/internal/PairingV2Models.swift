//
//  PairingV2Models.swift
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

enum PairingV2ApplicationMessage: Equatable {
    case hello(PairingV2HelloMessage)
    case recoveryCodeAvailable(PairingV2RecoveryCodeStatusMessage)
    case recoveryCodeRequest(PairingV2RecoveryCodeStatusMessage)
    case recoveryCodeAwaitingConfirmation(PairingV2RecoveryCodeTerminalMessage)
    case recoveryCodeConfirmed(PairingV2RecoveryCodeTerminalMessage)
    case recoveryCodeDenied(PairingV2RecoveryCodeTerminalMessage)
    case recoveryCodeUnavailable(PairingV2RecoveryCodeTerminalMessage)
    case recoveryCodeResponse(PairingV2RecoveryCodeResponseMessage)
}

enum PairingV2ProtocolVersion {
    static let current = "2"
}

struct PairingV2QRCodePayload: Codable, Equatable {
    let version: String
    let channelId: String
    let publicKey: String

    init(version: String = PairingV2ProtocolVersion.current, channelId: String, publicKey: String) {
        self.version = version
        self.channelId = channelId
        self.publicKey = publicKey
    }

    init?(url: URL) {
        guard Self.isPairing(url: url), let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            return nil
        }

        let params = fragment
            .split(separator: "&")
            .compactMap { part -> (String, String)? in
                let keyValue = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard keyValue.count == 2 else { return nil }
                return (keyValue[0], keyValue[1].removingPercentEncoding ?? keyValue[1])
            }

        let dict = Dictionary(uniqueKeysWithValues: params)
        guard let payload = dict["code2"],
              let payloadData = Self.decodePayload(payload),
              let decoded = try? JSONDecoder.snakeCaseKeys.decode(Self.self, from: payloadData),
              Self.supports(version: decoded.version) else {
            return nil
        }

        self = decoded
    }

    func toURL(baseURL: URL) throws -> URL {
        let url = baseURL.appendingPathComponent("sync/pairing/")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        urlComponents?.fragment = "&code2=\(Base64URL.encode(try JSONEncoder.snakeCaseKeys.encode(self)))"
        return urlComponents?.url ?? url
    }

    private static func isPairing(url: URL) -> Bool {
        url.pathComponents.contains("sync") && url.pathComponents.last == "pairing" && url.isPart(ofDomain: "duckduckgo.com")
    }

    private static func decodePayload(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value) {
            return data
        }
        return Base64URL.decode(value)
    }

    private static func supports(version: String) -> Bool {
        version == PairingV2ProtocolVersion.current
    }
}

struct PairingV2EncryptedMessage: Codable, Equatable {
    let version: String
    let payload: String

    init(version: String = PairingV2ProtocolVersion.current, payload: String) {
        self.version = version
        self.payload = payload
    }
}

struct PairingV2SequencedMessage: Codable, Equatable {
    let seq: Int
    let version: String
    let payload: String

    var encryptedMessage: PairingV2EncryptedMessage {
        PairingV2EncryptedMessage(version: version, payload: payload)
    }
}

struct PairingV2HelloMessage: Codable, Equatable {
    static let messageType = "hello"

    let type: String
    let channelId: String
    let publicKey: String
    let version: String

    init(channelId: String, publicKey: String, version: String = PairingV2ProtocolVersion.current) {
        self.type = Self.messageType
        self.channelId = channelId
        self.publicKey = publicKey
        self.version = version
    }
}

struct PairingV2RecoveryCodeStatusMessage: Codable, Equatable {
    let type: String
    let name: String?
    let kind: PairingV2DeviceKind
    let userId: String?

    init(type: String, name: String? = nil, kind: PairingV2DeviceKind, userId: String? = nil) {
        self.type = type
        self.name = name
        self.kind = kind
        self.userId = userId
    }
}

struct PairingV2RecoveryCodeTerminalMessage: Codable, Equatable {
    let type: String
}

struct PairingV2RecoveryCodeResponseMessage: Codable, Equatable {
    static let messageType = "recovery_code_response"

    let type: String
    let recoveryCode: String

    init(recoveryCode: String) {
        self.type = Self.messageType
        self.recoveryCode = recoveryCode
    }
}

extension PairingV2ApplicationMessage {

    enum MessageType {
        static let recoveryCodeAvailable = "recovery_code_available"
        static let recoveryCodeRequest = "recovery_code_request"
        static let recoveryCodeAwaitingConfirmation = "recovery_code_awaiting_confirmation"
        static let recoveryCodeConfirmed = "recovery_code_confirmed"
        static let recoveryCodeDenied = "recovery_code_denied"
        static let recoveryCodeUnavailable = "recovery_code_unavailable"
    }

    var type: String {
        switch self {
        case .hello(let message):
            return message.type
        case .recoveryCodeAvailable(let message),
                .recoveryCodeRequest(let message):
            return message.type
        case .recoveryCodeAwaitingConfirmation(let message),
                .recoveryCodeConfirmed(let message):
            return message.type
        case .recoveryCodeDenied(let message),
                .recoveryCodeUnavailable(let message):
            return message.type
        case .recoveryCodeResponse(let message):
            return message.type
        }
    }
}
