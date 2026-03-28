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
                name: "help",
                description: "Get a comprehensive guide to the PIR/DBP MCP debug server: available tools, workflows, and examples. Call this first to understand how to use the debug tools.",
                inputSchema: emptySchema()
            ),
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
                        "show_web_view": ["type": "boolean", "description": "Show the web view during scan (default: true)"],
                        "pause_on_error": ["type": "boolean", "description": "Keep WebView alive on failure for inspection with get_webview_state and execute_js (default: false). Set true for debugging."]
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
                description: "Set the staging API service root path for branch deploys. The DBP API always uses staging (https://dbp-staging.duckduckgo.com). The service_root is appended to the staging URL. Pass empty string to use the default staging endpoint.",
                inputSchema: schemaWith(
                    properties: [
                        "service_root": ["type": "string", "description": "Path appended to staging URL (e.g., '/branch-name'). Pass empty string to reset to default staging."]
                    ],
                    required: ["service_root"]
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
                        "show_web_view": ["type": "boolean", "description": "Show the web view during opt-out (default: true)"],
                        "pause_on_error": ["type": "boolean", "description": "Keep WebView alive on failure for inspection (default: true). Set false for simple audit runs."]
                    ],
                    required: ["extracted_profile", "first_name", "last_name", "city", "state", "birth_year"]
                )
            ),
            toolDef(
                name: "get_webview_state",
                description: "Get the current state of the debug WebView during an active scan or opt-out. Shows whether a scan/optout is running, the current action being executed, recent debug events, and any errors.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "reauthenticate",
                description: "Sign out of subscription (clears stale auth token) and open the activation flow in the browser for the user to re-authenticate. Use this after switching environments or when get_auth_status shows auth issues. After calling, wait for the user to complete sign-in, then use get_auth_status to verify.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "check_email_confirmation",
                description: "Check for email confirmation links from the backend after an opt-out that requires email confirmation (e.g. spokeo). Call this after run_optout returns 'awaiting email confirmation'. May need to be called multiple times until a link is found.",
                inputSchema: emptySchema()
            ),
            toolDef(
                name: "continue_optout",
                description: "Continue an opt-out after email confirmation link is found. Call check_email_confirmation first to verify a link exists. This runs the email confirmation step of the opt-out flow using the confirmation URL.",
                inputSchema: schemaWith(
                    properties: [
                        "broker_name": ["type": "string", "description": "The broker name or URL."],
                        "broker_json": ["type": "string", "description": "Optional: custom broker JSON."],
                        "extracted_profile": ["type": "object", "description": "The extracted profile from run_scan (must include id)."],
                        "first_name": ["type": "string", "description": "First name"],
                        "last_name": ["type": "string", "description": "Last name"],
                        "city": ["type": "string", "description": "City"],
                        "state": ["type": "string", "description": "State"],
                        "birth_year": ["type": "integer", "description": "Birth year"],
                        "show_web_view": ["type": "boolean", "description": "Show web view (default: true)"],
                        "pause_on_error": ["type": "boolean", "description": "Keep WebView alive on failure (default: false)."]
                    ],
                    required: ["extracted_profile", "first_name", "last_name", "city", "state", "birth_year"]
                )
            ),
            toolDef(
                name: "execute_js",
                description: "Execute JavaScript on the live debug WebView. Only works when a WebView is alive (paused on error after run_scan/run_optout). Use to inspect the page DOM, test CSS/XPath selectors, check element text, or verify fixes before updating broker JSON. The WebView stays alive until the next run_scan/run_optout call.",
                inputSchema: schemaWith(
                    properties: [
                        "javascript": ["type": "string", "description": "JavaScript expression to evaluate in the WebView. Returns the expression result."]
                    ],
                    required: ["javascript"]
                )
            ),
        ]
    }

    // MARK: - Tool Dispatch

    func callTool(name: String, arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        switch name {
        case "help":
            completion(.success(helpText()))
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
        case "reauthenticate":
            reauthenticate(completion: completion)
        case "execute_js":
            executeJS(arguments: arguments, completion: completion)
        case "check_email_confirmation":
            checkEmailConfirmation(completion: completion)
        case "continue_optout":
            continueOptOut(arguments: arguments, completion: completion)
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
        let pauseOnError = arguments["pause_on_error"] as? Bool ?? false

        resolveBrokerJSON(arguments: arguments) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let brokerData):
                self.agent.runCustomScan(brokerJSON: brokerData, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError) { data in
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
        let pauseOnError = arguments["pause_on_error"] as? Bool ?? false

        // Resolve broker JSON
        resolveBrokerJSON(arguments: arguments) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let brokerData):
                self.agent.runCustomOptOut(brokerJSON: brokerData, extractedProfileJSON: extractedProfileData, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError) { data in
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
        guard let serviceRoot = arguments["service_root"] as? String else {
            completion(.failure(ToolError.missingArgument("service_root")))
            return
        }

        agent.setAPIEndpoint(environment: "staging", serviceRoot: serviceRoot) { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to set API endpoint. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    private func reauthenticate(completion: @escaping (Result<String, Error>) -> Void) {
        // Sign out via XPC if agent is available (best-effort)
        agent.reauthenticate { _ in }

        // Open activation flow directly from MCP server — no XPC needed.
        let activationURLString = "https://duckduckgo.com/subscriptions/activation-flow"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "com.duckduckgo.macos.browser.debug", activationURLString]
        try? process.run()
        process.waitUntilExit()

        // Fallback if debug browser not found
        if process.terminationStatus != 0 {
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fallback.arguments = [activationURLString]
            try? fallback.run()
        }

        completion(.success("Activation flow opened in browser. Please sign in, then use get_auth_status to verify."))
    }

    private func checkEmailConfirmation(completion: @escaping (Result<String, Error>) -> Void) {
        agent.checkEmailConfirmation { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to check email confirmation. Is the agent running?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    private func continueOptOut(arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
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
        let pauseOnError = arguments["pause_on_error"] as? Bool ?? false

        resolveBrokerJSON(arguments: arguments) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let brokerData):
                self.agent.continueOptOut(brokerJSON: brokerData, extractedProfileJSON: extractedProfileData, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError) { data in
                    guard let data else {
                        completion(.failure(ToolError.xpcError("Continue opt-out failed — no response from agent.")))
                        return
                    }
                    self.prettyPrintJSON(data, completion: completion)
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func executeJS(arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        guard let javascript = arguments["javascript"] as? String else {
            completion(.failure(ToolError.missingArgument("javascript")))
            return
        }
        agent.executeJavaScript(code: javascript) { data in
            guard let data else {
                completion(.failure(ToolError.xpcError("Failed to execute JavaScript. Is the agent running and is a WebView alive?")))
                return
            }
            self.prettyPrintJSON(data, completion: completion)
        }
    }

    // MARK: - Help

    private func helpText() -> String {
        """
        # PIR/DBP MCP Debug Server

        Debug server for DuckDuckGo's Personal Information Removal (PIR) feature.
        Lets you inspect agent state, query broker data, run scans/optouts, and debug broker JSON.

        ## Quick Start

        1. get_agent_status — verify the PIR agent is running
        2. get_auth_status — verify auth token is valid
        3. list_brokers — see all brokers with scan status

        ## Tools by Category

        ### Production DB Inspection (read-only, queries the encrypted prod database)
        These tools inspect the real scan/optout state from the production scheduler.
        Use them to investigate user-reported issues, audit broker health, and check scan results.
        - get_agent_status: Agent version, running state, scheduler state
        - get_auth_status: Auth token validity, entitlement, environment, endpoint URL
        - list_brokers: All brokers with versions, match counts, error counts, last scan dates
        - get_broker_json: Full JSON step definitions for a broker (scan/optout actions)
        - get_broker_details: Per-profile-query scan and optout state for a broker
        - get_scan_history: Timeline of scan events for a broker + profile query
        - get_optout_history: Timeline of optout events for a broker + profile query + extracted profile
        - get_profile_queries: Configured name/address/birthYear combinations being scanned
        - query_logs: PIR system logs filtered by subsystem, level, and text

        ### Environment & Auth Management
        - start_immediate_scan: Trigger full production scan cycle (async, all brokers)
        - force_broker_update: Force broker JSON fetch, bypass hourly rate limiter
        - set_api_endpoint: Set staging API service root path for branch deploys
        - reauthenticate: Sign out + open activation flow for fresh auth token

        ### Broker JSON Development (isolated debug WebView, does NOT affect prod data)
        These tools run scans/optouts in a debug WebView with test profiles.
        Use them to develop, test, and fix broker JSON definitions.
        Results are NOT written to the production database.
        - run_scan: Run a scan for one broker with a test profile. Returns extracted profiles.
          - Accepts broker_name (DB lookup) or broker_json (custom JSON for testing fixes)
          - Set pause_on_error=true to keep WebView alive on failure for inspection
        - run_optout: Run optout for an extracted profile from run_scan results.
          - Pass the extracted_profile object from run_scan output
          - Set pause_on_error=true to keep WebView alive on failure
        - check_email_confirmation: Poll backend for email confirmation links (for brokers like spokeo)
        - continue_optout: Complete optout after email confirmation link is found

        ### Live WebView Inspection (only available during/after broker JSON development tools)
        - get_webview_state: Current URL, page HTML, action progress, errors.
          - Works during active scan/optout OR when paused on error (pause_on_error=true)
        - execute_js: Run JavaScript on the live/paused WebView.
          - Test CSS selectors, inspect DOM, verify text, debug broker JSON actions

        ## Workflows

        ### Audit a broker (pause_on_error=false)
        Quick check whether a broker's scan/optout works. No WebView inspection needed.
        1. run_scan(broker_name: "example.com", ..., pause_on_error: false)
        2. Success → broker works. Failure → note the error for investigation.

        ### Fix a broken broker (pause_on_error=true)
        When a broker is broken, use this workflow to diagnose and fix the JSON.
        IMPORTANT: Do NOT modify bundled broker JSON in the codebase. Instead, pass
        the fixed JSON via broker_json parameter to validate it.
        1. run_scan(broker_name: "example.com", ..., pause_on_error: true)
        2. Scan fails → WebView stays alive with page state
        3. get_webview_state → see currentURL, pageHTML, failed action details
        4. execute_js("document.querySelector('.some-selector')?.outerHTML") → test selectors
        5. execute_js("document.body.innerText.substring(0, 500)") → check page text
        6. Identify what changed (new selector, different text, restructured DOM)
        7. Construct fixed broker JSON based on findings
        8. run_scan(broker_json: "<fixed JSON>", ...) → validate the fix
        9. Repeat steps 3-8 until it works

        ### Explore a page for new broker JSON
        When building a new broker JSON from scratch, you need to see the live page.
        Use a minimal broker JSON with just a navigate action and a dummy extract that
        will fail — with pause_on_error=true, the WebView stays alive for exploration.
        1. run_scan(broker_json: '{"name":"new-broker","url":"newbroker.com","version":"1.0.0","steps":[{"stepType":"scan","actions":[{"actionType":"navigate","url":"https://newbroker.com/search/${firstName}-${lastName}/${state}/${city}"},{"actionType":"extract","selector":".dummy","profile":{}}]}]}', ..., pause_on_error: true)
        2. Navigate succeeds, extract fails → WebView stays alive on the search results page
        3. execute_js("document.querySelectorAll('.result-card').length") → explore the DOM
        4. execute_js("document.querySelector('.result-card')?.innerHTML") → inspect structure
        5. Build the real extract action based on findings

        ### Full optout flow (with email confirmation)
        1. run_scan(broker_name: "spokeo.com", ...) → get extracted profiles
        2. run_optout(broker_name: "spokeo.com", extracted_profile: <from step 1>, ...)
        3. Optout halts at "awaiting email confirmation"
        4. check_email_confirmation → poll for confirmation link (may need multiple calls)
        5. continue_optout(broker_name: "spokeo.com", extracted_profile: <same>, ...)

        ### Switch to a staging branch deploy
        1. set_api_endpoint(service_root: "/branch-name")
        2. reauthenticate → sign in on staging if needed
        3. get_auth_status → verify token is valid
        4. force_broker_update → get latest broker JSONs from staging
        5. Run scans/optouts against the staging branch

        ### Investigate production issues (read-only)
        Use production DB tools to investigate user-reported issues or broker health.
        These query the real encrypted database — no side effects.
        1. list_brokers → find brokers with high error counts
        2. get_broker_details(broker_name: "...") → see per-query scan/optout state
        3. get_scan_history / get_optout_history → drill into event timelines
        4. query_logs(filter: "broker_name") → check system logs for errors
        5. get_broker_json → read current step definitions to compare with site

        ## Broker JSON Format
        Broker definitions have steps (scan/optOut) containing actions:
        - navigate: Load a URL (supports ${firstName}, ${lastName}, ${city}, ${state} templates)
        - expectation: Wait for element/text/URL condition
        - click: Click elements by selector
        - fillForm: Fill form fields (email, profileUrl, etc.)
        - extract: Extract profile data from page
        - getCaptchaInfo / solveCaptcha: Handle captcha challenges
        - emailConfirmation: Wait for email confirmation
        """
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
