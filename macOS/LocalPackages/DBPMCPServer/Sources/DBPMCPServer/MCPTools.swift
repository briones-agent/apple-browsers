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
import MCP

// MARK: - Tool Error

enum ToolError: LocalizedError {
    case missingArgument(String)
    case xpcError(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): return "Missing required argument: \(name)"
        case .xpcError(let message): return "XPC error: \(message)"
        case .commandFailed(let message): return "Command failed: \(message)"
        }
    }
}

// MARK: - MCP Tools

final class MCPTools: @unchecked Sendable {
    let agent: AgentConnection

    init(agent: AgentConnection) {
        self.agent = agent
    }

    // MARK: - Tool Definitions

    func toolDefinitions() -> [Tool] {
        [
            tool("help",
                 "Get a comprehensive guide to the PIR/DBP MCP debug server: available tools, workflows, and examples."),
            tool("get_agent_status",
                 "Get PIR background agent status: version, running state, scheduler state, last background scheduler trigger time. Note: Last Trigger tracks only the periodic NSBackgroundActivityScheduler, not immediate scans from save_profile or start_immediate_scan."),
            tool("query_logs",
                 "Query PIR/DataBrokerProtection logs from the system log. Returns recent log entries filtered by subsystem.",
                 properties: [
                    "minutes": prop(.integer, "How many minutes of logs to fetch (default: 30, max: 1440)"),
                    "level": prop(.string, "Minimum log level: debug, info, default, error, fault (default: debug)"),
                    "filter": prop(.string, "Additional grep filter to apply to log output"),
                    "limit": prop(.integer, "Maximum number of log lines to return (default: 200, max: 2000)"),
                 ]),
            tool("start_immediate_scan",
                 "Trigger an immediate scan of all data brokers. Returns immediately; the scan runs asynchronously in the agent.",
                 properties: [
                    "show_web_view": prop(.boolean, "Show the web view during scan (default: false)"),
                 ]),
            tool("list_brokers",
                 "List all brokers from the encrypted DB with status summary: name, URL, version, parent, match count, error count, last scan date, and recent errors."),
            tool("get_broker_json",
                 "Get the full JSON definition for a specific broker. Returns the broker's scan/opt-out step definitions.",
                 properties: ["broker_url": prop(.string, "The broker URL or filename (e.g., 'peoplelooker.com')")],
                 required: ["broker_url"]),
            tool("get_broker_details",
                 "Get detailed per-profile-query scan and opt-out results for a specific broker.",
                 properties: ["broker_name": prop(.string, "The broker name or URL (e.g., 'PeopleLooker' or 'peoplelooker.com')")],
                 required: ["broker_name"]),
            tool("get_scan_history",
                 "Get scan history events for a specific broker and profile query.",
                 properties: [
                    "broker_id": prop(.integer, "The broker ID (from get_broker_details)"),
                    "profile_query_id": prop(.integer, "The profile query ID (from get_broker_details)"),
                 ],
                 required: ["broker_id", "profile_query_id"]),
            tool("get_optout_history",
                 "Get opt-out history events for a specific broker, profile query, and extracted profile.",
                 properties: [
                    "broker_id": prop(.integer, "The broker ID"),
                    "profile_query_id": prop(.integer, "The profile query ID"),
                    "extracted_profile_id": prop(.integer, "The extracted profile ID (from get_broker_details optOuts)"),
                 ],
                 required: ["broker_id", "profile_query_id", "extracted_profile_id"]),
            tool("get_broker_scheduler_state",
                 "Get raw scheduler state for a broker: preferredRunDate, lastRunDate, attemptCount for scan and each opt-out job, plus full history events. Use this to debug why jobs run too often or not at all.",
                 properties: [
                    "broker_name": prop(.string, "The broker name or URL"),
                    "profile_query_id": prop(.integer, "Optional: filter to a specific profile query ID. Pass 0 or omit for all."),
                    "extracted_profile_id": prop(.integer, "Optional: filter opt-outs to a specific extracted profile ID. Pass 0 or omit for all."),
                    "include_history": prop(.boolean, "Include full history events (default: true). Set false for compact output."),
                 ],
                 required: ["broker_name"]),
            tool("get_auth_status",
                 "Get auth/subscription status: whether the user is authenticated, has a valid access token and entitlement, which environment is active, and the current API endpoint URL."),
            tool("get_profile_queries",
                 "Get the configured profile queries being scanned."),
            tool("run_scan",
                 "Run a scan for a specific broker with the given profile. Returns extracted profiles on success, or error details on failure.",
                 properties: [
                    "broker_name": prop(.string, "The broker name or URL to scan."),
                    "broker_json": prop(.string, "Optional: custom broker JSON to use instead of the DB version."),
                    "first_name": prop(.string, "First name to scan for"),
                    "last_name": prop(.string, "Last name to scan for"),
                    "middle_name": prop(.string, "Middle name (optional)"),
                    "city": prop(.string, "City"),
                    "state": prop(.string, "State (2-letter abbreviation)"),
                    "birth_year": prop(.integer, "Birth year (e.g., 1980)"),
                    "show_web_view": prop(.boolean, "Show the web view during scan (default: true)"),
                    "pause_on_error": prop(.boolean, "Keep WebView alive on failure for inspection (default: true). Set false for batch audits."),
                 ],
                 required: ["first_name", "last_name", "city", "state", "birth_year"]),
            tool("force_broker_update",
                 "Force an immediate broker JSON update from the remote server, bypassing the hourly rate limiter."),
            tool("set_api_endpoint",
                 "Set the staging API service root path for branch deploys.",
                 properties: ["service_root": prop(.string, "Path appended to staging URL (e.g., '/branch-name'). Pass empty string to reset.")],
                 required: ["service_root"]),
            tool("run_optout",
                 "Run an opt-out for a specific extracted profile from a previous run_scan.",
                 properties: [
                    "broker_name": prop(.string, "The broker name or URL."),
                    "broker_json": prop(.string, "Optional: custom broker JSON."),
                    "extracted_profile": .object(["type": .string("object"), "description": .string("The extracted profile object from run_scan results.")]),
                    "first_name": prop(.string, "First name"),
                    "last_name": prop(.string, "Last name"),
                    "middle_name": prop(.string, "Middle name (optional)"),
                    "city": prop(.string, "City"),
                    "state": prop(.string, "State (2-letter abbreviation)"),
                    "birth_year": prop(.integer, "Birth year (e.g., 1980)"),
                    "show_web_view": prop(.boolean, "Show the web view (default: true)"),
                    "pause_on_error": prop(.boolean, "Keep WebView alive on failure (default: true). Set false for batch audits."),
                 ],
                 required: ["extracted_profile", "first_name", "last_name", "city", "state", "birth_year"]),
            tool("get_webview_state",
                 "Get the current state of the debug WebView during an active scan or opt-out."),
            tool("reauthenticate",
                 "Sign out of subscription and open the activation flow in the browser for re-authentication."),
            tool("check_email_confirmation",
                 "Check for email confirmation links from the backend after an opt-out that requires email confirmation."),
            tool("continue_optout",
                 "Continue an opt-out after email confirmation link is found.",
                 properties: [
                    "broker_name": prop(.string, "The broker name or URL."),
                    "broker_json": prop(.string, "Optional: custom broker JSON."),
                    "extracted_profile": .object(["type": .string("object"), "description": .string("The extracted profile from run_scan.")]),
                    "first_name": prop(.string, "First name"),
                    "last_name": prop(.string, "Last name"),
                    "middle_name": prop(.string, "Middle name (optional)"),
                    "city": prop(.string, "City"),
                    "state": prop(.string, "State"),
                    "birth_year": prop(.integer, "Birth year"),
                    "show_web_view": prop(.boolean, "Show web view (default: true)"),
                    "pause_on_error": prop(.boolean, "Keep WebView alive on failure (default: true)."),
                 ],
                 required: ["extracted_profile", "first_name", "last_name", "city", "state", "birth_year"]),
            tool("execute_js",
                 "Execute JavaScript on the live debug WebView. Only works when a WebView is alive (paused on error).",
                 properties: ["javascript": prop(.string, "JavaScript expression to evaluate in the WebView.")],
                 required: ["javascript"]),
            tool("restart_agent",
                 "Restart the PIR background agent via launchctl. Use after rebuilding the app or to recover from a stuck agent."),
            tool("remove_all_data",
                 "Remove all PIR data from the encrypted database: profile, scan history, opt-out history, extracted profiles. Use before save_profile for a clean slate."),
            tool("save_profile",
                 "Save (upsert) a profile to the encrypted database and automatically trigger an immediate scan. Supports multiple names and addresses. Profile queries are the cartesian product of names × addresses.",
                 properties: [
                    "names": .object(["type": .string("array"), "description": .string("Array of name objects, each with first_name (string), last_name (string), and optional middle_name (string).")]),
                    "addresses": .object(["type": .string("array"), "description": .string("Array of address objects, each with city (string) and state (string, 2-letter abbreviation).")]),
                    "birth_year": prop(.integer, "Birth year (e.g., 1980)"),
                 ],
                 required: ["names", "addresses", "birth_year"]),
        ]
    }

    // MARK: - Tool Dispatch

    func handleToolCall(params: CallTool.Parameters) async -> CallTool.Result {
        let args = params.decodedArguments
        do {
            let text: String
            switch params.name {
            case "help":
                text = helpText()
            case "get_agent_status":
                text = try await getAgentStatus()
            case "query_logs":
                text = try await queryLogs(args: args)
            case "start_immediate_scan":
                let showWebView = args.bool("show_web_view") ?? false
                agent.startImmediateOperations(showWebView: showWebView)
                text = "Immediate scan triggered (showWebView: \(showWebView))."
            case "list_brokers":
                text = try await xpcDataCall("broker data") { self.agent.getBrokerProfileData(completion: $0) }.listBrokersSummary()
            case "get_broker_json":
                let brokerURL = try args.requireString("broker_url")
                text = try await xpcDataCall("Broker JSON not found for '\(brokerURL)'") {
                    self.agent.getBrokerJSON(brokerURL: brokerURL, completion: $0)
                }.prettyJSON()
            case "get_broker_details":
                let brokerName = try args.requireString("broker_name")
                text = try await xpcDataCall("Broker '\(brokerName)' not found") {
                    self.agent.getBrokerDetails(brokerName: brokerName, completion: $0)
                }.prettyJSON()
            case "get_scan_history":
                let brokerId = try args.requireInt64("broker_id")
                let profileQueryId = try args.requireInt64("profile_query_id")
                text = try await xpcDataCall("Failed to fetch scan history") {
                    self.agent.getScanHistory(brokerId: brokerId, profileQueryId: profileQueryId, completion: $0)
                }.prettyJSON()
            case "get_optout_history":
                let brokerId = try args.requireInt64("broker_id")
                let profileQueryId = try args.requireInt64("profile_query_id")
                let extractedProfileId = try args.requireInt64("extracted_profile_id")
                text = try await xpcDataCall("Failed to fetch opt-out history") {
                    self.agent.getOptOutHistory(brokerId: brokerId, profileQueryId: profileQueryId, extractedProfileId: extractedProfileId, completion: $0)
                }.prettyJSON()
            case "get_broker_scheduler_state":
                let brokerName = try args.requireString("broker_name")
                let profileQueryId = args.int64("profile_query_id") ?? 0
                let extractedProfileId = args.int64("extracted_profile_id") ?? 0
                let includeHistory = args.bool("include_history") ?? true
                text = try await xpcDataCall("Failed to fetch scheduler state") {
                    self.agent.getSchedulerState(brokerName: brokerName, profileQueryId: profileQueryId, extractedProfileId: extractedProfileId, includeHistory: includeHistory, completion: $0)
                }.prettyJSON()
            case "get_auth_status":
                text = try await xpcDataCall("Failed to fetch auth status") { self.agent.getAuthStatus(completion: $0) }.prettyJSON()
            case "get_profile_queries":
                text = try await getProfileQueries()
            case "run_scan":
                text = try await runScan(args: args)
            case "force_broker_update":
                text = try await xpcDataCall("Failed to force broker update") { self.agent.forceBrokerUpdate(completion: $0) }.prettyJSON()
            case "set_api_endpoint":
                let serviceRoot = try args.requireString("service_root")
                text = try await xpcDataCall("Failed to set API endpoint") {
                    self.agent.setAPIEndpoint(environment: "staging", serviceRoot: serviceRoot, completion: $0)
                }.prettyJSON()
            case "run_optout":
                text = try await runOptOut(args: args)
            case "get_webview_state":
                text = try await xpcDataCall("Failed to get WebView state") { self.agent.getWebViewState(completion: $0) }.prettyJSON()
            case "reauthenticate":
                text = reauthenticate()
            case "check_email_confirmation":
                text = try await xpcDataCall("Failed to check email confirmation") { self.agent.checkEmailConfirmation(completion: $0) }.prettyJSON()
            case "continue_optout":
                text = try await continueOptOut(args: args)
            case "execute_js":
                let javascript = try args.requireString("javascript")
                text = try await xpcDataCall("Failed to execute JavaScript. Is a WebView alive?") {
                    self.agent.executeJavaScript(code: javascript, completion: $0)
                }.prettyJSON()
            case "restart_agent":
                text = try restartAgent()
            case "remove_all_data":
                text = try await xpcDataCall("Failed to remove all data") { self.agent.removeAllData(completion: $0) }.prettyJSON()
            case "save_profile":
                text = try await saveProfile(args: args)
            default:
                return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Tool Implementations

    private func getAgentStatus() async throws -> String {
        let metadata: DBPAgentMetadata? = await withCheckedContinuation { c in
            agent.getDebugMetadata { nonisolated(unsafe) let m = $0; c.resume(returning: m) }
        }
        guard let metadata else { throw ToolError.xpcError("Failed to get debug metadata. Is the PIR background agent running?") }

        var lines = ["PIR Background Agent Status", "==========================="]
        lines.append("Version:          \(metadata.backgroundAgentVersion)")
        lines.append("Running:          \(metadata.isAgentRunning)")
        lines.append("Scheduler State:  \(metadata.agentSchedulerState)")

        if let ts = metadata.lastSchedulerSessionStartTimestamp {
            let date = Date(timeIntervalSince1970: ts)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lines.append("Last Trigger:     \(formatter.string(from: date))")
            let minutes = Int(Date().timeIntervalSince(date) / 60)
            lines.append("                  (\(minutes / 60 > 0 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m") ago)")
        } else {
            lines.append("Last Trigger:     never")
        }
        return lines.joined(separator: "\n")
    }

    private func queryLogs(args: DecodedArguments) async throws -> String {
        let minutes = min(args.int("minutes") ?? 30, 1440)
        let level = args.string("level") ?? "debug"
        let filter = args.string("filter")
        let limit = min(args.int("limit") ?? 200, 2000)

        let validLevels = ["debug", "info", "default", "error", "fault"]
        guard validLevels.contains(level) else { throw ToolError.missingArgument("level must be one of: \(validLevels.joined(separator: ", "))") }

        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                let predicate = "(subsystem == 'PIR' OR subsystem == 'DBP Background Agent' OR subsystem CONTAINS 'DataBrokerProtection') AND processImagePath BEGINSWITH '/Applications/DEBUG/'"
                var logArgs = ["show", "--predicate", predicate, "--last", "\(minutes)m", "--style", "compact"]
                switch level {
                case "debug": logArgs += ["--info", "--debug"]
                case "info": logArgs += ["--info"]
                default: logArgs += ["--level", level]
                }
                process.arguments = logArgs
                let pipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                guard (try? process.run()) != nil else {
                    continuation.resume(returning: "Failed to run log command.")
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard var output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: "No log output returned.")
                    return
                }

                if let filter, !filter.isEmpty {
                    output = output.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
                }
                let lines = output.components(separatedBy: "\n")
                if lines.count > limit {
                    output = "... (\(lines.count - limit) lines truncated) ...\n" + Array(lines.suffix(limit)).joined(separator: "\n")
                }
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output = "No matching log entries found in the last \(minutes) minutes."
                }
                continuation.resume(returning: output)
            }
        }
    }

    private func getProfileQueries() async throws -> String {
        let data = try await xpcDataCall("Failed to fetch profile data") { self.agent.getBrokerProfileData(completion: $0) }
        guard let brokers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return "No profile data." }

        var seen = Set<String>()
        var queries = [[String: Any]]()
        for broker in brokers {
            if let pq = broker["profileQuery"] as? [String: Any], let key = pq["fullName"] as? String, !seen.contains(key) {
                seen.insert(key)
                queries.append(pq)
            }
        }
        return queries.isEmpty ? "No profile queries found." : queries.prettyJSONArray()
    }

    private func runScan(args: DecodedArguments) async throws -> String {
        let firstName = try args.requireString("first_name")
        let lastName = try args.requireString("last_name")
        let middleName = args.string("middle_name")
        let city = try args.requireString("city")
        let state = try args.requireString("state")
        let birthYear = try args.requireInt("birth_year")
        let showWebView = args.bool("show_web_view") ?? true
        let pauseOnError = args.bool("pause_on_error") ?? true

        let brokerData = try await resolveBrokerJSON(args: args)
        let data = try await xpcDataCall("Scan failed — no response from agent") {
            self.agent.runCustomScan(brokerJSON: brokerData, firstName: firstName, lastName: lastName, middleName: middleName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError, completion: $0)
        }
        return data.prettyJSON()
    }

    private func runOptOut(args: DecodedArguments) async throws -> String {
        let extractedProfileData = try args.requireJSONData("extracted_profile")
        let firstName = try args.requireString("first_name")
        let lastName = try args.requireString("last_name")
        let middleName = args.string("middle_name")
        let city = try args.requireString("city")
        let state = try args.requireString("state")
        let birthYear = try args.requireInt("birth_year")
        let showWebView = args.bool("show_web_view") ?? true
        let pauseOnError = args.bool("pause_on_error") ?? true

        let brokerData = try await resolveBrokerJSON(args: args)
        let data = try await xpcDataCall("Opt-out failed — no response from agent") {
            self.agent.runCustomOptOut(brokerJSON: brokerData, extractedProfileJSON: extractedProfileData, firstName: firstName, lastName: lastName, middleName: middleName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError, completion: $0)
        }
        return data.prettyJSON()
    }

    private func continueOptOut(args: DecodedArguments) async throws -> String {
        let extractedProfileData = try args.requireJSONData("extracted_profile")
        let firstName = try args.requireString("first_name")
        let lastName = try args.requireString("last_name")
        let middleName = args.string("middle_name")
        let city = try args.requireString("city")
        let state = try args.requireString("state")
        let birthYear = try args.requireInt("birth_year")
        let showWebView = args.bool("show_web_view") ?? true
        let pauseOnError = args.bool("pause_on_error") ?? true

        let brokerData = try await resolveBrokerJSON(args: args)
        let data = try await xpcDataCall("Continue opt-out failed — no response from agent") {
            self.agent.continueOptOut(brokerJSON: brokerData, extractedProfileJSON: extractedProfileData, firstName: firstName, lastName: lastName, middleName: middleName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError, completion: $0)
        }
        return data.prettyJSON()
    }

    private func reauthenticate() -> String {
        agent.reauthenticate { _ in }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "com.duckduckgo.macos.browser.debug", "https://duckduckgo.com/subscriptions/activation-flow"]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fallback.arguments = ["https://duckduckgo.com/subscriptions/activation-flow"]
            try? fallback.run()
        }
        return "Activation flow opened in browser. Use get_auth_status to verify."
    }

    // MARK: - Agent Lifecycle

    private func restartAgent() throws -> String {
        let uid = getuid()
        let label = agent.machServiceName
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(uid)/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ToolError.commandFailed("launchctl kickstart exited with status \(process.terminationStatus)")
        }
        return "Agent restarted (\(label)). XPC connection will reconnect on next tool call."
    }

    // MARK: - Profile Management

    private func saveProfile(args: DecodedArguments) async throws -> String {
        let birthYear = try args.requireInt("birth_year")

        guard let namesRaw = args.array("names"), !namesRaw.isEmpty else {
            throw ToolError.missingArgument("names (array of {first_name, last_name, middle_name?})")
        }
        guard let addressesRaw = args.array("addresses"), !addressesRaw.isEmpty else {
            throw ToolError.missingArgument("addresses (array of {city, state})")
        }

        var names: [[String: Any]] = []
        for nameObj in namesRaw {
            guard let dict = nameObj as? [String: Any],
                  let firstName = dict["first_name"] as? String,
                  let lastName = dict["last_name"] as? String else {
                throw ToolError.missingArgument("Each name must have first_name and last_name")
            }
            var name: [String: Any] = ["firstName": firstName, "lastName": lastName]
            if let middleName = dict["middle_name"] as? String {
                name["middleName"] = middleName
            }
            names.append(name)
        }

        var addresses: [[String: Any]] = []
        for addrObj in addressesRaw {
            guard let dict = addrObj as? [String: Any],
                  let city = dict["city"] as? String,
                  let state = dict["state"] as? String else {
                throw ToolError.missingArgument("Each address must have city and state")
            }
            addresses.append(["city": city, "state": state])
        }

        let profileDict: [String: Any] = [
            "names": names,
            "addresses": addresses,
            "phones": [String](),
            "birthYear": birthYear
        ]
        let profileJSON = try JSONSerialization.data(withJSONObject: profileDict, options: [])
        return try await xpcDataCall("Failed to save profile") {
            self.agent.saveProfile(profileJSON: profileJSON, completion: $0)
        }.prettyJSON()
    }

    // MARK: - XPC Helpers

    private func xpcDataCall(_ errorMessage: String, call: @escaping (@escaping (Data?) -> Void) -> Void) async throws -> Data {
        let data = await withCheckedContinuation { c in call { c.resume(returning: $0) } }
        guard let data else { throw ToolError.xpcError(errorMessage + ". Is the agent running?") }
        return data
    }

    private func resolveBrokerJSON(args: DecodedArguments) async throws -> Data {
        if let customJSON = args.string("broker_json"), let jsonData = customJSON.data(using: .utf8) {
            return jsonData
        }
        let brokerName = try args.requireString("broker_name")
        return try await xpcDataCall("Broker '\(brokerName)' not found. Use list_brokers to see available brokers.") {
            self.agent.getBrokerJSON(brokerURL: brokerName, completion: $0)
        }
    }

    // MARK: - Tool Definition Helpers

    private enum PropType: String { case string, integer, boolean, object }

    private func prop(_ type: PropType, _ description: String) -> Value {
        .object(["type": .string(type.rawValue), "description": .string(description)])
    }

    private func tool(_ name: String, _ description: String, properties: [String: Value] = [:], required: [String] = []) -> Tool {
        var schema: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return Tool(name: name, description: description, inputSchema: .object(schema))
    }

    // MARK: - Help

    private func helpText() -> String {
        """
        # PIR/DBP MCP Debug Server

        Debug server for DuckDuckGo's Personal Information Removal (PIR) feature.
        Communicates with the PIR background agent via XPC to query state, run operations, and read logs.

        ## Quick Start
        1. get_agent_status — verify the PIR agent is running
        2. get_auth_status — verify auth token is valid and check which environment is active
        3. list_brokers — see all brokers with scan status, error counts, and versions

        ## Tools by Category

        ### Production DB Inspection (read-only)
        - get_agent_status — agent version, running state, scheduler state, last background scheduler trigger
        - get_auth_status — token validity, environment, API endpoint URL
        - list_brokers — all brokers with version, match/error counts, last scan date
        - get_broker_json — full scan/opt-out step definitions for a broker
        - get_broker_details — per-profile scan and opt-out results (returns broker_id, profile_query_id)
        - get_scan_history — scan events for a broker+profile (needs IDs from get_broker_details)
        - get_optout_history — opt-out events (needs IDs from get_broker_details)
        - get_broker_scheduler_state — raw scheduler state: run dates, attempt counts, history
        - get_profile_queries — configured profile queries being scanned
        - query_logs — system logs filtered by PIR subsystems and debug build variant

        ### Profile & Data Management
        - save_profile — create or update profile (multiple names × addresses). Auto-triggers immediate scan.
        - remove_all_data — wipe all PIR data (profile, scan history, opt-out history, extracted profiles)
        - restart_agent — restart the PIR background agent via launchctl

        ### Environment & Auth
        - start_immediate_scan — trigger async scan of all brokers (use after force_broker_update or to re-scan same profile)
        - force_broker_update — force broker JSON update, bypass hourly rate limit
        - set_api_endpoint — switch staging API service root for branch deploys
        - reauthenticate — sign out and open activation flow for re-auth

        ### Broker JSON Development (isolated debug WebView)
        - run_scan — scan a broker with given profile, optional custom JSON
        - run_optout — opt-out for an extracted profile from a previous scan
        - check_email_confirmation — check for email confirmation links post-opt-out
        - continue_optout — continue opt-out after email confirmation

        ### Live WebView Inspection
        - get_webview_state — current URL, page HTML, active step, last error
        - execute_js — run JavaScript on the live debug WebView

        ## Key Workflows

        ### Full reset and scan with new profile
        1. remove_all_data → wipe everything
        2. restart_agent → clean slate
        3. save_profile(names: [...], addresses: [...], birth_year: 1990) → saves profile AND auto-triggers immediate scan
        4. get_agent_status / list_brokers → monitor progress

        ### Update profile and re-scan
        1. save_profile(names: [...], addresses: [...], birth_year: 1990) → upserts profile, auto-triggers immediate scan

        ### Re-scan same profile (e.g. after broker JSON update)
        1. force_broker_update → pull latest JSONs
        2. start_immediate_scan → re-scan with current profile and updated JSONs

        ### Fix a broken broker
        1. run_scan(broker_name: "spokeo.com", first_name: ...) → fails, WebView stays alive (pause_on_error defaults to true)
        2. get_webview_state → see current URL, page content, and error
        3. execute_js(javascript: "document.querySelector(...)") → inspect DOM
        4. Edit the broker JSON based on findings
        5. run_scan(broker_name: "spokeo.com", broker_json: "<fixed JSON>", ...) → test the fix
        6. run_optout(...) → verify opt-out flow works too

        ### Build new broker JSON from scratch
        1. run_scan with minimal JSON (navigate + dummy extract) → page loads, extract fails, WebView stays alive
        2. execute_js to explore DOM: find selectors, check page structure
        3. Build JSON iteratively, test each version with run_scan(broker_json: ...)
        4. Once scan works, test opt-out with run_optout(broker_json: ...)

        ### Diagnose stuck or failing scans
        1. get_agent_status → is the agent running? (Last Trigger = last background scheduler fire, not last immediate scan)
        2. get_auth_status → is the token valid? correct environment?
        3. get_broker_scheduler_state(broker_name: "...", include_history: true) → check preferredRunDate, attemptCount
        4. query_logs(minutes: 60, filter: "spokeo") → look for errors in logs

        ### Switch to staging branch deploy
        1. set_api_endpoint(service_root: "/my-branch") → point to staging
        2. get_auth_status → confirm endpoint changed
        3. force_broker_update → pull latest JSONs from staging
        4. list_brokers → verify broker versions updated

        ### Test opt-out with email confirmation
        1. run_scan(...) → get extracted profiles
        2. run_optout(..., extracted_profile: <from scan>) → starts opt-out, may need email confirmation
        3. check_email_confirmation → poll for confirmation link from backend
        4. continue_optout(...) → resume opt-out after confirmation

        ## Important Tips
        - save_profile auto-triggers an immediate scan (same as the real app UI flow)
        - start_immediate_scan is for re-scanning without changing the profile (e.g. after force_broker_update)
        - Last Trigger in get_agent_status = last NSBackgroundActivityScheduler fire, NOT last immediate scan
        - Tool IDs chain: list_brokers → get_broker_details (returns broker_id, profile_query_id) → get_scan_history / get_optout_history
        - pause_on_error (default: true) keeps the WebView alive after failures — use get_webview_state and execute_js to inspect
        - Set pause_on_error: false for batch audits where you don't need to inspect failures
        - query_logs automatically filters to debug build variant (no prod/review log noise)
        - run_scan/run_optout/continue_optout accept optional broker_json to test custom JSON without modifying the DB
        - middle_name is optional on run_scan, run_optout, continue_optout, and save_profile
        """
    }
}

// MARK: - Argument Decoding

/// Type-safe argument extraction from MCP CallTool parameters.
struct DecodedArguments {
    private let dict: [String: Any]

    init(from arguments: [String: Value]?) {
        if let args = arguments,
           let data = try? JSONEncoder().encode(args),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.dict = dict
        } else {
            self.dict = [:]
        }
    }

    func string(_ key: String) -> String? { dict[key] as? String }
    func int(_ key: String) -> Int? { dict[key] as? Int }
    func int64(_ key: String) -> Int64? { (dict[key] as? Int64) ?? (dict[key] as? Int).map(Int64.init) }
    func bool(_ key: String) -> Bool? { dict[key] as? Bool }
    func array(_ key: String) -> [Any]? { dict[key] as? [Any] }

    func requireString(_ key: String) throws -> String {
        guard let v = string(key) else { throw ToolError.missingArgument(key) }
        return v
    }
    func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw ToolError.missingArgument(key) }
        return v
    }
    func requireInt64(_ key: String) throws -> Int64 {
        guard let v = int64(key) else { throw ToolError.missingArgument(key) }
        return v
    }
    func requireJSONData(_ key: String) throws -> Data {
        guard let obj = dict[key], let data = try? JSONSerialization.data(withJSONObject: obj) else {
            throw ToolError.missingArgument(key)
        }
        return data
    }
}

extension CallTool.Parameters {
    var decodedArguments: DecodedArguments { DecodedArguments(from: arguments) }
}

// MARK: - Data Formatting Extensions

extension Data {
    func prettyJSON() -> String {
        if let json = try? JSONSerialization.jsonObject(with: self),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            return str
        }
        return String(data: self, encoding: .utf8) ?? "Failed to decode response."
    }

    func listBrokersSummary() -> String {
        let tmpPath = NSTemporaryDirectory() + "dbp-mcp-list-brokers.json"
        if let pretty = try? JSONSerialization.data(withJSONObject: (try? JSONSerialization.jsonObject(with: self)) as Any, options: [.prettyPrinted, .sortedKeys]) {
            try? pretty.write(to: URL(fileURLWithPath: tmpPath))
        } else {
            try? self.write(to: URL(fileURLWithPath: tmpPath))
        }

        guard let brokers = try? JSONSerialization.jsonObject(with: self) as? [[String: Any]] else {
            return "Results written to: \(tmpPath)"
        }

        let summary: [[String: Any]] = brokers.map { b in
            var entry: [String: Any] = ["name": b["name"] ?? "", "errors": b["errorCount"] ?? 0, "matches": b["totalMatches"] ?? 0]
            if let parent = b["parent"] as? String { entry["parent"] = parent }
            if let lastScan = b["lastScanDate"] as? String { entry["lastScanDate"] = lastScan }
            return entry
        }

        let result: [String: Any] = ["count": brokers.count, "fullDataPath": tmpPath, "brokers": summary]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Results written to: \(tmpPath)"
    }
}

extension Array where Element == [String: Any] {
    func prettyJSONArray() -> String {
        if let data = try? JSONSerialization.data(withJSONObject: self, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Found \(count) items but failed to serialize."
    }
}
