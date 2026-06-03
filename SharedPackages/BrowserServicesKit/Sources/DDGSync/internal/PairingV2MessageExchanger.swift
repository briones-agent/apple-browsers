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
    let sendRetryDelaysNanoseconds: [UInt64]

    init(endpoints: Endpoints,
         api: RemoteAPIRequestCreating,
         sendRetryDelaysNanoseconds: [UInt64] = [200_000_000, 500_000_000]) {
        self.endpoints = endpoints
        self.api = api
        self.sendRetryDelaysNanoseconds = sendRetryDelaysNanoseconds
    }

    func openChannel(_ channelID: String) async throws {
        let request = api.createRequest(url: channelURL(channelID),
                                        method: .put,
                                        headers: [:],
                                        parameters: [:],
                                        body: nil,
                                        contentType: nil)
        let result = try await request.execute()
        guard result.response.statusCode.isSuccessfulHTTPStatusCode else {
            throw SyncError.unexpectedStatusCode(result.response.statusCode)
        }
    }

    func send(_ messages: [PairingV2EncryptedMessage], to channelID: String) async throws {
        let body = try JSONEncoder.snakeCaseKeys.encode(SendMessagesRequest(messages: messages))
        try await send(body: body, to: channelID, retryDelaysNanoseconds: sendRetryDelaysNanoseconds)
    }

    private func send(body: Data, to channelID: String, retryDelaysNanoseconds: [UInt64]) async throws {
        let request = api.createRequest(url: messagesURL(channelID),
                                        method: .post,
                                        headers: [:],
                                        parameters: [:],
                                        body: body,
                                        contentType: "application/json")
        do {
            let result = try await request.execute()
            guard result.response.statusCode.isSuccessfulHTTPStatusCode else {
                throw SyncError.unexpectedStatusCode(result.response.statusCode)
            }
        } catch SyncError.unexpectedStatusCode(404) where !retryDelaysNanoseconds.isEmpty {
            try await Task.sleep(nanoseconds: retryDelaysNanoseconds[0])
            try await send(body: body, to: channelID, retryDelaysNanoseconds: Array(retryDelaysNanoseconds.dropFirst()))
        } catch SyncError.unexpectedStatusCode(404) {
            throw PairingV2Error.relayChannelUnavailable
        } catch SyncError.unexpectedStatusCode(410) {
            throw PairingV2Error.relayChannelExpired
        }
    }

    func fetchMessages(from channelID: String, after sequence: Int) async throws -> [PairingV2SequencedMessage] {
        let request = api.createRequest(url: messagesURL(channelID),
                                        method: .get,
                                        headers: [:],
                                        parameters: ["after": String(sequence)],
                                        body: nil,
                                        contentType: nil)
        do {
            let result = try await request.execute()
            guard result.response.statusCode.isSuccessfulHTTPStatusCode else {
                throw SyncError.unexpectedStatusCode(result.response.statusCode)
            }
            guard let body = result.data else {
                throw SyncError.noResponseBody
            }
            return try JSONDecoder.snakeCaseKeys.decode(FetchMessagesResponse.self, from: body).messages
        } catch SyncError.unexpectedStatusCode(404) {
            throw PairingV2Error.relayChannelUnavailable
        } catch SyncError.unexpectedStatusCode(410) {
            throw PairingV2Error.relayChannelExpired
        }
    }

    func closeChannel(_ channelID: String) async throws {
        let request = api.createRequest(url: channelURL(channelID),
                                        method: .delete,
                                        headers: [:],
                                        parameters: [:],
                                        body: nil,
                                        contentType: nil)
        do {
            let result = try await request.execute()
            guard result.response.statusCode.isSuccessfulHTTPStatusCode else {
                throw SyncError.unexpectedStatusCode(result.response.statusCode)
            }
        } catch SyncError.unexpectedStatusCode(404), SyncError.unexpectedStatusCode(410) {
            return
        }
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

private extension Int {

    var isSuccessfulHTTPStatusCode: Bool {
        (200..<300).contains(self)
    }
}
