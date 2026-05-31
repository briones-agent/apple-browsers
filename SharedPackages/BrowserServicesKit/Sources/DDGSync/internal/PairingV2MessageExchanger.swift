//
//  PairingV2MessageExchanger.swift
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

protocol PairingV2MessageExchanging {
    func openChannel(_ channelID: String) async throws
    func send(_ messages: [PairingV2EncryptedMessage], to channelID: String) async throws
    func fetchMessages(from channelID: String, after sequence: Int) async throws -> [PairingV2SequencedMessage]
    func closeChannel(_ channelID: String) async throws
}

struct PairingV2MessageExchanger: PairingV2MessageExchanging {

    let endpoints: Endpoints
    let api: RemoteAPIRequestCreating

    func openChannel(_ channelID: String) async throws {
        let request = api.createRequest(url: channelURL(channelID),
                                        method: .put,
                                        headers: [:],
                                        parameters: [:],
                                        body: nil,
                                        contentType: nil)
        let result = try await request.execute()
        // API currently documents 200, while the deployed service has returned 204.
        // Treat both as success until the contract and deployment converge.
        guard [200, 204].contains(result.response.statusCode) else {
            throw SyncError.unexpectedStatusCode(result.response.statusCode)
        }
    }

    func send(_ messages: [PairingV2EncryptedMessage], to channelID: String) async throws {
        let body = try JSONEncoder.snakeCaseKeys.encode(SendMessagesRequest(messages: messages))
        let request = api.createRequest(url: messagesURL(channelID),
                                        method: .post,
                                        headers: [:],
                                        parameters: [:],
                                        body: body,
                                        contentType: "application/json")
        let result = try await request.execute()
        // A first send can rarely see 404 while a just-created relay channel is still
        // replicating. This implementation intentionally aborts and lets the user retry
        // the whole pairing flow; targeted retry may be added later if needed.
        guard result.response.statusCode == 204 else {
            throw SyncError.unexpectedStatusCode(result.response.statusCode)
        }
    }

    func fetchMessages(from channelID: String, after sequence: Int) async throws -> [PairingV2SequencedMessage] {
        let request = api.createRequest(url: messagesURL(channelID),
                                        method: .get,
                                        headers: [:],
                                        parameters: ["after": String(sequence)],
                                        body: nil,
                                        contentType: nil)
        let result = try await request.execute()
        guard let body = result.data else {
            throw SyncError.noResponseBody
        }
        return try JSONDecoder.snakeCaseKeys.decode(FetchMessagesResponse.self, from: body).messages
    }

    func closeChannel(_ channelID: String) async throws {
        let request = api.createRequest(url: channelURL(channelID),
                                        method: .delete,
                                        headers: [:],
                                        parameters: [:],
                                        body: nil,
                                        contentType: nil)
        _ = try await request.execute()
    }

    private struct SendMessagesRequest: Encodable {
        let messages: [PairingV2EncryptedMessage]
    }

    private struct FetchMessagesResponse: Decodable {
        let messages: [PairingV2SequencedMessage]
    }

    private func channelURL(_ channelID: String) -> URL {
        endpoints.pairingV2Exchange.appendingPathComponent(channelID)
    }

    private func messagesURL(_ channelID: String) -> URL {
        channelURL(channelID).appendingPathComponent("messages")
    }
}
