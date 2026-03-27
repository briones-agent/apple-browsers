//
//  MCPTools.swift
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

// MARK: - Tool Error

enum ToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case xpcError(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .missingArgument(let name): return "Missing required argument: \(name)"
        case .xpcError(let message): return "XPC error: \(message)"
        case .commandFailed(let message): return "Command failed: \(message)"
        }
    }
}

// MARK: - Phase 1 Tool Definitions

/// Defines and dispatches MCP tools that map to XPC methods on the PIR background agent.
///
/// Phase 1 tools: get_agent_status, query_logs, start_immediate_scan,
/// list_brokers, get_broker_json, get_broker_details, get_profile_queries, run_scan
final class MCPTools {
    private let agent: AgentConnection

    init(agent: AgentConnection) {
        self.agent = agent
    }

    func listTools() -> [[String: Any]] {
        return [
            toolDef(
                name: "get_agent_status",
                description: "Get PIR background agent status: version, running state, scheduler state, last trigger time.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "query_logs",
                description: "Query PIR/DataBrokerProtection logs from the system log. Returns recent log entries filtered by subsystem.",
                inputSchema: schemaWith(properties: [
                    "minutes": ["type": "integer", "description": "How many minutes of logs to fetch (default: 30, max: 1440)"],
                    "level": ["type": "string", "description": "Minimum log level: debug, info, default, error, fault (default: debug)"],
                    "filter": ["type": "string", "description": "Additional grep filter to apply to log output"],
                    "limit": ["type": "integer", "description": "Maximum number of log lines to return (default: 200, max: 2000)"]
                ])
            ),
            toolDef(
                name: "start_immediate_scan",
                description: "Trigger an immediate scan of all data brokers. Returns immediately; the scan runs asynchronously in the agent.",
                inputSchema: schemaWith(properties: [
                    "show_web_view": ["type": "boolean", "description": "Show the web view during scan (default: false)"]
                ])
            ),
            toolDef(
                name: "list_brokers",
                description: "List all brokers from the encrypted DB with status summary: name, URL, version, parent, match count, error count, last scan date, and recent errors.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "get_broker_json",
                description: "Get the full JSON definition for a specific broker. Returns the broker's scan/opt-out step definitions.",
                inputSchema: schemaWith(
                    properties: [
                        "broker_url": ["type": "string", "description": "The broker URL or filename (e.g., 'peoplelooker.com')"]
                    ],
                    required: ["broker_url"]
                )
            ),
            toolDef(
                name: "get_broker_details",
                description: "Get detailed per-profile-query scan and opt-out results for a specific broker. Shows each profile query's scan status, extracted profiles, opt-out progress, and errors.",
                inputSchema: schemaWith(
                    properties: [
                        "broker_name": ["type": "string", "description": "The broker name or URL (e.g., 'PeopleLooker' or 'peoplelooker.com')"]
                    ],
                    required: ["broker_name"]
                )
            ),
            toolDef(
                name: "get_scan_history",
                description: "Get scan history events for a specific broker and profile query. Shows the timeline of scan attempts, results, and errors.",
                inputSchema: schemaWith(
                    properties: [
                        "broker_id": ["type": "integer", "description": "The broker ID (from list_brokers or get_broker_details)"],
                        "profile_query_id": ["type": "integer", "description": "The profile query ID (from get_broker_details)"]
                    ],
                    required: ["broker_id", "profile_query_id"]
                )
            ),
            toolDef(
                name: "get_optout_history",
                description: "Get opt-out history events for a specific broker, profile query, and extracted profile. Shows the timeline of opt-out attempts, status progression, and errors.",
                inputSchema: schemaWith(
                    properties: [
                        "broker_id": ["type": "integer", "description": "The broker ID"],
                        "profile_query_id": ["type": "integer", "description": "The profile query ID"],
                        "extracted_profile_id": ["type": "integer", "description": "The extracted profile ID (from get_broker_details optOuts)"]
                    ],
                    required: ["broker_id", "profile_query_id", "extracted_profile_id"]
                )
            ),
            toolDef(
                name: "get_auth_status",
                description: "Get auth/subscription status: whether the user is authenticated, has a valid access token and entitlement, which environment is active (production/staging), and the current API endpoint URL.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "get_profile_queries",
                description: "Get the configured profile queries being scanned. Shows the name, address, birth year combinations used for scanning.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "run_scan",
                description: "Run a scan for a specific broker with the given profile. Uses the broker's JSON definition from the DB (or custom JSON if provided). Returns extracted profiles on success, or error details on failure.",
                inputSchema: schemaWith(
                    properties: [
                        "broker_name": ["type": "string", "description": "The broker name or URL to scan. The broker JSON is loaded from the DB."],
                        "broker_json": ["type": "string", "description": "Optional: custom broker JSON to use instead of the DB version."],
                        "first_name": ["type": "string", "description": "First name to scan for"],
                        "last_name": ["type": "string", "description": "Last name to scan for"],
                        "city": ["type": "string", "description": "City"],
                        "state": ["type": "string", "description": "State (2-letter abbreviation)"],
                        "birth_year": ["type": "integer", "description": "Birth year (e.g., 1980)"],
                        "show_web_view": ["type": "boolean", "description": "Show the web view during scan (default: true)"]
                    ],
                    required: ["first_name", "last_name", "city", "state", "birth_year"]
                )
            ),
            toolDef(
                name: "force_broker_update",
                description: "Force an immediate broker JSON update from the remote server, bypassing the hourly rate limiter. Resets delivery data (ETag, timestamp) so the next check fetches fresh data.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "set_api_endpoint",
                description: "Switch the DBP API environment between production and staging, with an optional service root path for staging branch deploys.",
                inputSchema: schemaWith(
                    properties: [
                        "environment": ["type": "string", "description": "API environment: 'production' or 'staging'"],
                        "service_root": ["type": "string", "description": "Optional path appended to staging URL for branch deploys (e.g., '/branch-name'). Ignored for production. Pass empty string to reset."]
                    ],
                    required: ["environment"]
                )
            ),
            toolDef(
                name: "run_optout",
                description: "Run an opt-out for a specific extracted profile from a previous run_scan. Provide the same broker and profile info used for the scan, plus the extracted_profile JSON object from the scan results.",
                inputSchema: schemaWith(
                    properties: [
                        "broker_name": ["type": "string", "description": "The broker name or URL. The broker JSON is loaded from the DB."],
                        "broker_json": ["type": "string", "description": "Optional: custom broker JSON to use instead of the DB version."],
                        "extracted_profile": ["type": "object", "description": "The extracted profile object from run_scan results (must include at minimum identifier or name+addresses)."],
                        "first_name": ["type": "string", "description": "First name"],
                        "last_name": ["type": "string", "description": "Last name"],
                        "city": ["type": "string", "description": "City"],
                        "state": ["type": "string", "description": "State (2-letter abbreviation)"],
                        "birth_year": ["type": "integer", "description": "Birth year (e.g., 1980)"],
                        "show_web_view": ["type": "boolean", "description": "Show the web view during opt-out (default: true)"]
                    ],
                    required: ["extracted_profile", "first_name", "last_name", "city", "state", "birth_year"]
                )
            ),
            toolDef(
                name: "get_webview_state",
                description: "Get the current state of the debug WebView during an active scan or opt-out. Shows whether a scan/optout is running, the current action being executed, recent debug events, and any errors.",
                inputSchema: emptySchema()
            ),
        ]
    }

    // MARK: - Tool Dispatch

    func callTool(name: String, arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        switch name {
        case "get_agent_status":
            getAgentStatus(completion: completion)
        case "query_logs":
            queryLogs(arguments: arguments, completion: completion)
        case "start_immediate_scan":
            let showWebView = arguments["show_web_view"] as? Bool ?? false
            agent.startImmediateOperations(showWebView: showWebView)
            completion(.success("Immediate scan triggered (showWebView: \(showWebView)). The scan is running asynchronously in the agent."))
        case "list_brokers":
            listBrokers(completion: completion)
        case "get_broker_json":
            guard let brokerURL = arguments["broker_url"] as? String else {
                completion(.failure(ToolError.missingArgument("broker_url")))
                return
            }
            getBrokerJSON(brokerURL: brokerURL, completion: completion)
        case "get_broker_details":
            guard let brokerName = arguments["broker_name"] as? String else {
                completion(.failure(ToolError.missingArgument("broker_name")))
                return
            }
            getBrokerDetails(brokerName: brokerName, completion: completion)
        case "get_scan_history":
            guard let brokerId = arguments["broker_id"] as? Int64 ?? (arguments["broker_id"] as? Int).map(Int64.init),
                  let profileQueryId = arguments["profile_query_id"] as? Int64 ?? (arguments["profile_query_id"] as? Int).map(Int64.init) else {
                completion(.failure(ToolError.missingArgument("broker_id and profile_query_id")))
                return
            }
            getScanHistory(brokerId: brokerId, profileQueryId: profileQueryId, completion: completion)
        case "get_optout_history":
            guard let brokerId = arguments["broker_id"] as? Int64 ?? (arguments["broker_id"] as? Int).map(Int64.init),
                  let profileQueryId = arguments["profile_query_id"] as? Int64 ?? (arguments["profile_query_id"] as? Int).map(Int64.init),
                  let extractedProfileId = arguments["extracted_profile_id"] as? Int64 ?? (arguments["extracted_profile_id"] as? Int).map(Int64.init) else {
                completion(.failure(ToolError.missingArgument("broker_id, profile_query_id, and extracted_profile_id")))
                return
            }
            getOptOutHistory(brokerId: brokerId, profileQueryId: profileQueryId, extractedProfileId: extractedProfileId, completion: completion)
        case "get_auth_status":
            getAuthStatus(completion: completion)
        case "get_profile_queries":
            getProfileQueries(completion: completion)
        case "run_scan":
            runScan(arguments: arguments, completion: completion)
        case "force_broker_update":
            forceBrokerUpdate(completion: completion)
        case "set_api_endpoint":
            setAPIEndpoint(arguments: arguments, completion: completion)
        case "run_optout":
            runOptOut(arguments: arguments, completion: completion)
        case "get_webview_state":
            getWebViewState(completion: completion)
        default:
            completion(.failure(ToolError.unknownTool(name)))
        }
    }

    // MARK: - Tool Implementations

    private func getAgentStatus(completion: @escaping (Result<String, Error>) -> Void) {
        agent.getDebugMetadata { metadata in
            guard let metadata else {
                completion(.failure(ToolError.xpcError("Failed to get debug metadata. Is the PIR background agent running?")))
                return
            }

            var lines = [String]()
            lines.append("PIR Background Agent Status")
            lines.append("===========================")
            lines.append("Version:          \(metadata.backgroundAgentVersion)")
            lines.append("Running:          \(metadata.isAgentRunning)")
            lines.append("Scheduler State:  \(metadata.agentSchedulerState)")

            if let ts = metadata.lastSchedulerSessionStartTimestamp {
                let date = Date(timeIntervalSince1970: ts)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                lines.append("Last Trigger:     \(formatter.string(from: date))")

                let elapsed = Date().timeIntervalSince(date)
                let minutes = Int(elapsed / 60)
                let hours = minutes / 60
                let remainingMinutes = minutes % 60
                if hours > 0 {
                    lines.append("                  (\(hours)h \(remainingMinutes)m ago)")
                } else {
                    lines.append("                  (\(minutes)m ago)")
                }
            } else {
                lines.append("Last Trigger:     never")
            }

            completion(.success(lines.joined(separator: "\n")))
        }
    }

    private func queryLogs(arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        let minutes = min(arguments["minutes"] as? Int ?? 30, 1440)
        let level = arguments["level"] as? String ?? "debug"
        let filter = arguments["filter"] as? String
        let limit = min(arguments["limit"] as? Int ?? 200, 2000)

        let validLevels = ["debug", "info", "default", "error", "fault"]
        guard validLevels.contains(level) else {
            completion(.failure(ToolError.missingArgument("level must be one of: \(validLevels.joined(separator: ", "))")))
            return
        }

        Thread.detachNewThread {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            var args = [
                "show",
                "--predicate", "subsystem == 'PIR' OR subsystem == 'DBP Background Agent' OR subsystem CONTAINS 'DataBrokerProtection'",
                "--last", "\(minutes)m",
                "--style", "compact",
            ]
            switch level {
            case "debug":
                args += ["--info", "--debug"]
            case "info":
                args += ["--info"]
            default:
                args += ["--level", level]
            }
            process.arguments = args

            let pipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                completion(.failure(ToolError.commandFailed("Failed to run log command: \(error.localizedDescription)")))
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard var output = String(data: data, encoding: .utf8) else {
                completion(.success("No log output returned."))
                return
            }

            if let filter, !filter.isEmpty {
                let lines = output.components(separatedBy: "\n")
                let filtered = lines.filter { $0.localizedCaseInsensitiveContains(filter) }
                output = filtered.joined(separator: "\n")
            }

            let lines = output.components(separatedBy: "\n")
            if lines.count > limit {
                let truncated = Array(lines.suffix(limit))
                output = "... (\(lines.count - limit) lines truncated) ...\n" + truncated.joined(separator: "\n")
            }

            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = "No matching log entries found in the last \(minutes) minutes."
            }

            completion(.success(output))
        }
    }

    // MARK: - DB Query Tools

    private func listBrokers(completion: @escaping (Result<String, Error>) -> Void) {
        agent.getBrokerProfileData { data in
            guard let data, let jsonString = String(data: data, encoding: .utf8) else {
                completion(.failure(ToolError.xpcError("Failed to fetch broker data from agent. Is the agent running?")))
                return
            }
            completion(.success(jsonString))
        }
    }

    private func getBrokerJSON(brokerURL: String, completion: @escaping (Result<String, Error>) -> Void) {
        agent.getBrokerJSON(brokerURL: brokerURL) { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Broker JSON not found for '\(brokerURL)'. Try using the broker's domain (e.g., 'peoplelooker.com').")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    private func getBrokerDetails(brokerName: String, completion: @escaping (Result<String, Error>) -> Void) {
        agent.getBrokerDetails(brokerName: brokerName) { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Broker '\(brokerName)' not found. Use list_brokers to see available brokers.")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    private func getProfileQueries(completion: @escaping (Result<String, Error>) -> Void) {
        // Profile queries are embedded in the broker profile data response.
        // Extract unique profile queries from the data.
        agent.getBrokerProfileData { data in
            guard let data,
                  let brokers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(.failure(ToolError.xpcError("Failed to fetch profile data from agent. Is the agent running?")))
                return
            }

            var seen = Set<String>()
            var queries = [[String: Any]]()

            for broker in brokers {
                if let pq = broker["profileQuery"] as? [String: Any],
                   let key = pq["fullName"] as? String {
                    if !seen.contains(key) {
                        seen.insert(key)
                        queries.append(pq)
                    }
                }
            }

            if queries.isEmpty {
                completion(.success("No profile queries found. Has a profile been saved?"))
                return
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: queries, options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                completion(.success(jsonString))
            } else {
                completion(.success("Found \(queries.count) profile queries but failed to serialize them."))
            }
        }
    }

    private func runScan(arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        guard let firstName = arguments["first_name"] as? String,
              let lastName = arguments["last_name"] as? String,
              let city = arguments["city"] as? String,
              let state = arguments["state"] as? String,
              let birthYear = arguments["birth_year"] as? Int else {
            completion(.failure(ToolError.missingArgument("first_name, last_name, city, state, and birth_year are required")))
            return
        }

        let showWebView = arguments["show_web_view"] as? Bool ?? true

        resolveBrokerJSON(arguments: arguments) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let brokerData):
                self.agent.runCustomScan(brokerJSON: brokerData, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView) { data in
                    self.handleScanResult(data: data, completion: completion)
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func handleScanResult(data: Data?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let data else {
            completion(.failure(ToolError.xpcError("Scan failed — no response from agent. The agent may have crashed or timed out.")))
            return
        }
        prettyPrintJSON(data, completion: completion)
    }

    private func getScanHistory(brokerId: Int64, profileQueryId: Int64, completion: @escaping (Result<String, Error>) -> Void) {
        agent.getScanHistory(brokerId: brokerId, profileQueryId: profileQueryId) { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to fetch scan history. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    private func getOptOutHistory(brokerId: Int64, profileQueryId: Int64, extractedProfileId: Int64, completion: @escaping (Result<String, Error>) -> Void) {
        agent.getOptOutHistory(brokerId: brokerId, profileQueryId: profileQueryId, extractedProfileId: extractedProfileId) { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to fetch opt-out history. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    private func getAuthStatus(completion: @escaping (Result<String, Error>) -> Void) {
        agent.getAuthStatus { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to fetch auth status. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    // MARK: - Action Tools

    private func forceBrokerUpdate(completion: @escaping (Result<String, Error>) -> Void) {
        agent.forceBrokerUpdate { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to force broker update. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    private func runOptOut(arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        guard let extractedProfileObj = arguments["extracted_profile"],
              let extractedProfileData = try? JSONSerialization.data(withJSONObject: extractedProfileObj) else {
            completion(.failure(ToolError.missingArgument("extracted_profile")))
            return
        }
        guard let firstName = arguments["first_name"] as? String,
              let lastName = arguments["last_name"] as? String,
              let city = arguments["city"] as? String,
              let state = arguments["state"] as? String,
              let birthYear = arguments["birth_year"] as? Int else {
            completion(.failure(ToolError.missingArgument("first_name, last_name, city, state, and birth_year are required")))
            return
        }

        let showWebView = arguments["show_web_view"] as? Bool ?? true

        // Resolve broker JSON
        resolveBrokerJSON(arguments: arguments) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let brokerData):
                self.agent.runCustomOptOut(brokerJSON: brokerData, extractedProfileJSON: extractedProfileData, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView) { data in
                    guard let data else {
                        completion(.failure(ToolError.xpcError("Opt-out failed — no response from agent.")))
                        return
                    }
                    self.prettyPrintJSON(data, completion: completion)
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getWebViewState(completion: @escaping (Result<String, Error>) -> Void) {
        agent.getWebViewState { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to get WebView state. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    /// Resolves broker JSON from either `broker_json` (custom) or `broker_name` (DB lookup).
    private func resolveBrokerJSON(arguments: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        if let customJSON = arguments["broker_json"] as? String,
           let jsonData = customJSON.data(using: .utf8) {
            completion(.success(jsonData))
            return
        }
        guard let brokerName = arguments["broker_name"] as? String else {
            completion(.failure(ToolError.missingArgument("Either broker_name or broker_json is required")))
            return
        }
        agent.getBrokerJSON(brokerURL: brokerName) { brokerData in
            guard let brokerData else {
                completion(.failure(ToolError.xpcError("Broker '\(brokerName)' not found. Use list_brokers to see available brokers.")))
                return
            }
            completion(.success(brokerData))
        }
    }

    private func setAPIEndpoint(arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        guard let environment = arguments["environment"] as? String else {
            completion(.failure(ToolError.missingArgument("environment")))
            return
        }
        let serviceRoot = arguments["service_root"] as? String ?? ""

        agent.setAPIEndpoint(environment: environment, serviceRoot: serviceRoot) { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to set API endpoint. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    // MARK: - Helpers

    private func prettyPrintJSON(_ data: Data, completion: @escaping (Result<String, Error>) -> Void) {
        if let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            completion(.success(prettyString))
        } else if let rawString = String(data: data, encoding: .utf8) {
            completion(.success(rawString))
        } else {
            completion(.failure(ToolError.xpcError("Failed to decode response data.")))
        }
    }

    private func toolDef(name: String, description: String, inputSchema: [String: Any]) -> [String: Any] {
        return ["name": name, "description": description, "inputSchema": inputSchema]
    }

    private func emptySchema() -> [String: Any] {
        return ["type": "object", "properties": [:] as [String: Any]]
    }

    private func schemaWith(properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }
}
