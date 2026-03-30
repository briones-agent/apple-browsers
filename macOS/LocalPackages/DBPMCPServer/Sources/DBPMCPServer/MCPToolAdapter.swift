//
//  MCPToolAdapter.swift
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
import MCP

// MARK: - Adapter from existing MCPTools to MCP SDK types

extension MCPTools {

    /// Convert existing tool definitions to MCP SDK Tool type.
    func toolDefinitions() -> [Tool] {
        listTools().compactMap { dict -> Tool? in
            guard let name = dict["name"] as? String,
                  let description = dict["description"] as? String else { return nil }

            let inputSchema: Value
            if let schema = dict["inputSchema"] as? [String: Any],
               let schemaData = try? JSONSerialization.data(withJSONObject: schema),
               let schemaValue = try? JSONDecoder().decode(Value.self, from: schemaData) {
                inputSchema = schemaValue
            } else {
                inputSchema = .object(["type": .string("object"), "properties": .object([:])])
            }

            return Tool(name: name, description: description, inputSchema: inputSchema)
        }
    }

    /// Handle a CallTool request by bridging to the existing completion-based callTool.
    func handleToolCall(params: CallTool.Parameters) async -> CallTool.Result {
        // Convert SDK arguments (Value?) to [String: Any]
        let arguments: [String: Any]
        if let args = params.arguments,
           let data = try? JSONEncoder().encode(args),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = dict
        } else {
            arguments = [:]
        }

        return await withCheckedContinuation { continuation in
            callTool(name: params.name, arguments: arguments) { result in
                switch result {
                case .success(let text):
                    continuation.resume(returning: .init(content: [.text(text: text, annotations: nil, _meta: nil)]))
                case .failure(let error):
                    continuation.resume(returning: .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true))
                }
            }
        }
    }
}
