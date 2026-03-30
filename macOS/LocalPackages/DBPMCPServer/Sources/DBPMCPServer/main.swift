//
//  main.swift
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

/// Debug-only MCP server for PIR (Data Broker Protection) debugging.
///
/// Communicates with Claude Code over stdio (JSON-RPC 2.0 via MCP SDK) and connects to the
/// PIR background agent via XPC to query state, trigger operations, and read logs.
///
/// Usage:
///   dbp-mcp-server [--mach-service <name>]

func parseMachServiceName() -> String {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--mach-service"), idx + 1 < args.count {
        return args[idx + 1]
    }
    return "com.duckduckgo.macos.DBP.backgroundAgent.debug"
}

func log(_ message: String) {
    let data = (message + "\n").data(using: .utf8)!
    FileHandle.standardError.write(data)
}

let machServiceName = parseMachServiceName()
log("dbp-mcp-server starting (mach service: \(machServiceName))")

let agent = AgentConnection(machServiceName: machServiceName)
let tools = MCPTools(agent: agent)

let server = Server(
    name: "dbp-mcp-server",
    version: "2.0.0",
    capabilities: .init(tools: .init())
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: tools.toolDefinitions())
}

await server.withMethodHandler(CallTool.self) { params in
    await tools.handleToolCall(params: params)
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
