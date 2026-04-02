//
//  DataBrokerProtectionAgentManager+MCP.swift
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
import DataBrokerProtectionCore
import os.log

// MARK: - MCP Debug Server Support
//
// All MCP-related methods are isolated in this extension to keep the main
// DataBrokerProtectionAgentManager clean and minimize merge conflicts when
// integrating the MCP debug branch into feature branches.

extension DataBrokerProtectionAgentManager {

    // MARK: - Profile Management

    public func removeAllData() async -> Data? {
        do {
            try mcpDataManager.communicator.deleteProfileData()
            let result: [String: Any] = ["success": true, "message": "All PIR data removed"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = ["success": false, "error": error.localizedDescription]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func saveProfile(profileJSON: Data) async -> Data? {
        do {
            let profile = try JSONDecoder().decode(DataBrokerProtectionProfile.self, from: profileJSON)
            try await mcpDataManager.saveProfile(profile)
            let queries = profile.profileQueries
            // Trigger the same flow as the UI: pixel events, auth refresh, immediate scan
            await profileSaved()
            let result: [String: Any] = [
                "success": true,
                "message": "Profile saved with \(profile.names.count) name(s), \(profile.addresses.count) address(es), \(queries.count) profile query/queries. Immediate scan triggered."
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = ["success": false, "error": error.localizedDescription]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    // MARK: - Read-Only Inspection

    public func getBrokerProfileData() async -> Data? {
        do {
            let allData = try mcpDataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var brokerMap = [String: [BrokerProfileQueryData]]()
            for item in allData {
                brokerMap[item.dataBroker.name, default: []].append(item)
            }

            var brokerSummaries = [[String: Any]]()
            for (brokerName, items) in brokerMap.sorted(by: { $0.key < $1.key }) {
                guard let first = items.first else { continue }
                let broker = first.dataBroker

                let allEvents = items.flatMap { $0.events }
                let errorEvents = allEvents.filter { $0.isError }
                let totalMatches = items.reduce(0) { $0 + $1.extractedProfiles.count }
                let lastScanDate = items.compactMap { $0.scanJobData.lastRunDate }.max()
                let recentErrors = errorEvents.sorted { $0.date > $1.date }.prefix(5)

                var summary: [String: Any] = [
                    "name": brokerName,
                    "url": broker.url,
                    "version": broker.version,
                    "profileQueryCount": items.count,
                    "totalMatches": totalMatches,
                    "errorCount": errorEvents.count,
                ]

                if let parent = broker.parent {
                    summary["parent"] = parent
                }
                if let lastScan = lastScanDate {
                    summary["lastScanDate"] = formatter.string(from: lastScan)
                }
                if !recentErrors.isEmpty {
                    summary["recentErrors"] = recentErrors.map { event -> [String: Any] in
                        var dict: [String: Any] = ["date": formatter.string(from: event.date)]
                        if let error = event.error {
                            dict["error"] = error
                        }
                        return dict
                    }
                }

                // Include profile query info for get_profile_queries extraction
                let uniqueQueries = Set(items.map { "\($0.profileQuery.firstName) \($0.profileQuery.lastName)" })
                if let firstQuery = items.first?.profileQuery {
                    summary["profileQuery"] = [
                        "firstName": firstQuery.firstName,
                        "lastName": firstQuery.lastName,
                        "city": firstQuery.city,
                        "state": firstQuery.state,
                        "birthYear": firstQuery.birthYear,
                        "fullName": firstQuery.fullName,
                    ] as [String: Any]
                }

                brokerSummaries.append(summary)
            }

            return try JSONSerialization.data(withJSONObject: brokerSummaries, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch broker profile data: \(error.localizedDescription)")
            return nil
        }
    }

    public func getBrokerJSON(brokerURL: String) async -> Data? {
        do {
            let allData = try mcpDataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let normalizedURL = brokerURL.replacingOccurrences(of: ".json", with: "")

            let broker = allData.first(where: {
                $0.dataBroker.url == normalizedURL ||
                $0.dataBroker.name.lowercased() == normalizedURL.lowercased()
            })?.dataBroker

            guard let broker else { return nil }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(broker)
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch broker JSON: \(error.localizedDescription)")
            return nil
        }
    }

    public func getBrokerDetails(brokerName: String) async -> Data? {
        do {
            let allData = try mcpDataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let brokerItems = allData.filter {
                $0.dataBroker.name.lowercased() == brokerName.lowercased() ||
                $0.dataBroker.url.lowercased() == brokerName.lowercased()
            }

            guard !brokerItems.isEmpty, let broker = brokerItems.first?.dataBroker else { return nil }

            var profileQueries = [[String: Any]]()
            for item in brokerItems {
                let query = item.profileQuery
                let scan = item.scanJobData

                var scanInfo: [String: Any] = [:]
                if let lastRun = scan.lastRunDate {
                    scanInfo["lastRunDate"] = formatter.string(from: lastRun)
                }
                if let preferredRun = scan.preferredRunDate {
                    scanInfo["preferredRunDate"] = formatter.string(from: preferredRun)
                }

                let scanEvents = scan.historyEvents.sorted { $0.date > $1.date }
                if let latest = scanEvents.first {
                    switch latest.type {
                    case .noMatchFound:
                        scanInfo["lastResult"] = "noMatchFound"
                    case .matchesFound(let count):
                        scanInfo["lastResult"] = "matchesFound"
                        scanInfo["matchCount"] = count
                    case .error:
                        scanInfo["lastResult"] = "error"
                        if let error = latest.error {
                            scanInfo["lastError"] = error
                        }
                    case .scanStarted:
                        scanInfo["lastResult"] = "scanStarted"
                    default:
                        scanInfo["lastResult"] = String(describing: latest.type)
                    }
                    scanInfo["lastEventDate"] = formatter.string(from: latest.date)
                }
                scanInfo["totalErrors"] = scan.historyEvents.filter { $0.isError }.count

                var optOuts = [[String: Any]]()
                for optOut in item.optOutJobData {
                    var optOutInfo: [String: Any] = [
                        "extractedProfileId": optOut.extractedProfile.id ?? -1,
                        "extractedProfileName": optOut.extractedProfile.fullName ?? optOut.extractedProfile.name ?? "unknown",
                        "attemptCount": optOut.attemptCount,
                    ]

                    if let addr = optOut.extractedProfile.addresses?.first {
                        optOutInfo["extractedProfileAddress"] = "\(addr.city), \(addr.state)"
                    }
                    if let lastRun = optOut.lastRunDate {
                        optOutInfo["lastRunDate"] = formatter.string(from: lastRun)
                    }
                    if let preferredRun = optOut.preferredRunDate {
                        optOutInfo["preferredRunDate"] = formatter.string(from: preferredRun)
                    }
                    if let submitted = optOut.submittedSuccessfullyDate {
                        optOutInfo["submittedDate"] = formatter.string(from: submitted)
                    }
                    if let removed = optOut.extractedProfile.removedDate {
                        optOutInfo["removedDate"] = formatter.string(from: removed)
                    }

                    let optOutEvents = optOut.historyEvents.sorted { $0.date > $1.date }
                    if let latest = optOutEvents.first {
                        switch latest.type {
                        case .optOutStarted: optOutInfo["status"] = "started"
                        case .optOutRequested: optOutInfo["status"] = "requested"
                        case .optOutConfirmed: optOutInfo["status"] = "confirmed"
                        case .optOutSubmittedAndAwaitingEmailConfirmation: optOutInfo["status"] = "awaitingEmailConfirmation"
                        case .error:
                            optOutInfo["status"] = "error"
                            if let error = latest.error { optOutInfo["lastError"] = error }
                        case .reAppearence: optOutInfo["status"] = "reAppeared"
                        case .matchRemovedByUser: optOutInfo["status"] = "removedByUser"
                        default: optOutInfo["status"] = String(describing: latest.type)
                        }
                    }
                    optOutInfo["totalErrors"] = optOut.historyEvents.filter { $0.isError }.count
                    optOuts.append(optOutInfo)
                }

                var queryDict: [String: Any] = [
                    "profileQueryId": query.id ?? -1,
                    "firstName": query.firstName,
                    "lastName": query.lastName,
                    "city": query.city,
                    "state": query.state,
                    "scan": scanInfo,
                ]
                if !optOuts.isEmpty {
                    queryDict["optOuts"] = optOuts
                }
                profileQueries.append(queryDict)
            }

            let result: [String: Any] = [
                "brokerId": broker.id ?? -1,
                "brokerName": broker.name,
                "brokerURL": broker.url,
                "version": broker.version,
                "parent": broker.parent ?? NSNull(),
                "profileQueryCount": brokerItems.count,
                "profileQueries": profileQueries,
            ]

            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch broker details: \(error.localizedDescription)")
            return nil
        }
    }

    public func getSchedulerState(brokerName: String, profileQueryId: Int64, extractedProfileId: Int64, historyType: String?) async -> Data? {
        let includeScanHistory = historyType == "scan" || historyType == "all"
        let includeOptOutHistory = historyType == "optout" || historyType == "all"
        do {
            let allData = try mcpDataManager.fetchBrokerProfileQueryData(ignoresCache: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let brokerItems = allData.filter {
                $0.dataBroker.name.lowercased() == brokerName.lowercased() ||
                $0.dataBroker.url.lowercased() == brokerName.lowercased()
            }

            let filteredItems = profileQueryId > 0
                ? brokerItems.filter { $0.profileQuery.id == profileQueryId }
                : brokerItems

            guard !filteredItems.isEmpty else { return nil }

            let broker = filteredItems.first!.dataBroker
            var queryResults = [[String: Any]]()

            for item in filteredItems {
                let scan = item.scanJobData

                var scanRow: [String: Any] = [
                    "brokerId": broker.id ?? -1,
                    "profileQueryId": item.profileQuery.id ?? -1,
                ]
                if let date = scan.preferredRunDate { scanRow["preferredRunDate"] = formatter.string(from: date) }
                if let date = scan.lastRunDate { scanRow["lastRunDate"] = formatter.string(from: date) }

                var scanHistory: [[String: Any]]?
                if includeScanHistory {
                    scanHistory = scan.historyEvents.sorted { $0.date < $1.date }.map { serializeHistoryEvent($0, formatter: formatter) }
                }

                let optOuts = extractedProfileId > 0
                    ? item.optOutJobData.filter { $0.extractedProfile.id == extractedProfileId }
                    : item.optOutJobData

                var optOutRows = [[String: Any]]()
                var optOutHistories = [String: [[String: Any]]]()

                for optOut in optOuts {
                    let epId = optOut.extractedProfile.id ?? -1
                    var row: [String: Any] = [
                        "extractedProfileId": epId,
                        "extractedProfileName": optOut.extractedProfile.fullName ?? optOut.extractedProfile.name ?? "unknown",
                        "attemptCount": optOut.attemptCount,
                    ]
                    if let date = optOut.preferredRunDate { row["preferredRunDate"] = formatter.string(from: date) }
                    if let date = optOut.lastRunDate { row["lastRunDate"] = formatter.string(from: date) }
                    if let date = optOut.submittedSuccessfullyDate { row["submittedSuccessfullyDate"] = formatter.string(from: date) }
                    optOutRows.append(row)

                    if includeOptOutHistory {
                        let events = optOut.historyEvents.sorted { $0.date < $1.date }.map { serializeHistoryEvent($0, formatter: formatter) }
                        optOutHistories["\(epId)"] = events
                    }
                }

                var queryResult: [String: Any] = [
                    "scanRow": scanRow,
                    "optOutRows": optOutRows,
                ]
                if let scanHistory { queryResult["scanHistory"] = scanHistory }
                if includeOptOutHistory { queryResult["optOutHistory"] = optOutHistories }

                if let configData = try? JSONEncoder().encode(broker.schedulingConfig),
                   let configDict = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                    queryResult["schedulingConfig"] = configDict
                }

                queryResults.append(queryResult)
            }

            let result: [String: Any] = [
                "brokerName": broker.name,
                "brokerURL": broker.url,
                "profileQueries": queryResults,
            ]

            return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Failed to fetch scheduler state: \(error.localizedDescription)")
            return nil
        }
    }

    public func getAuthStatus() async -> Data? {
        let settings = DataBrokerProtectionSettings(defaults: .dbp)
        let isAuthenticated = await mcpAuthenticationManager.isUserAuthenticated
        let hasToken = await mcpAuthenticationManager.accessToken() != nil
        var hasEntitlement = false
        do {
            hasEntitlement = try await mcpAuthenticationManager.hasValidEntitlement()
        } catch {}

        let result: [String: Any] = [
            "isAuthenticated": isAuthenticated,
            "hasAccessToken": hasToken,
            "hasValidEntitlement": hasEntitlement,
            "environment": settings.selectedEnvironment.rawValue,
            "endpointURL": settings.endpointURL.absoluteString,
        ]

        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Actions

    public func forceBrokerUpdate() async -> Data? {
        let settings = DataBrokerProtectionSettings(defaults: .dbp)
        settings.resetBrokerDeliveryData()

        do {
            try await mcpBrokerUpdater.checkForUpdates(skipsLimiter: true)
            let result: [String: Any] = [
                "success": true,
                "message": "Broker JSON update completed. Rate limiter bypassed, delivery data reset.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func setAPIEndpoint(environment: String, serviceRoot: String) async -> Data? {
        let settings = DataBrokerProtectionSettings(defaults: .dbp)

        if let env = DataBrokerProtectionSettings.SelectedEnvironment(rawValue: environment) {
            settings.selectedEnvironment = env
        } else {
            let result: [String: Any] = [
                "success": false,
                "error": "Invalid environment '\(environment)'. Must be 'production' or 'staging'.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        settings.serviceRoot = serviceRoot

        let result: [String: Any] = [
            "success": true,
            "environment": settings.selectedEnvironment.rawValue,
            "serviceRoot": settings.serviceRoot,
            "endpointURL": settings.endpointURL.absoluteString,
        ]
        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    public func reauthenticate() async -> Data? {
        await mcpAuthenticationManager.signOut()

        let activationURLString = "https://duckduckgo.com/subscriptions/activation-flow"
        let browserBundleID = Bundle.main.bundleIdentifier?
            .replacingOccurrences(of: ".DBP.backgroundAgent", with: "") ?? "com.duckduckgo.macos.browser.debug"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", browserBundleID, activationURLString]
        try? process.run()

        let result: [String: Any] = [
            "success": true,
            "message": "Signed out. Activation flow opened in browser — please sign in to get a fresh auth token. Use get_auth_status to verify when done.",
        ]
        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Debug Scan/OptOut/WebView State

    public func runCustomScan(brokerJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        let session = createDebugSession()
        let emailService = makeDebugEmailConfirmationService(for: session)
        session.updateState { s in
            s.isRunning = true
            s.currentStep = "scan"
            s.currentAction = nil
            s.lastError = nil
            s.debugEvents.removeAll()
            s.lastExtractedProfiles.removeAll()
        }

        do {
            let broker = try JSONDecoder().decode(DataBroker.self, from: brokerJSON)
            let resolvedBroker = broker.with(id: DebugHelper.stableId(for: broker))

            let profile = DataBrokerProtectionProfile(
                names: [.init(firstName: firstName, lastName: lastName, middleName: middleName)],
                addresses: [.init(city: city, state: state)],
                phones: [],
                birthYear: birthYear
            )

            var allExtracted = [ExtractedProfile]()

            for profileQuery in profile.profileQueries {
                let queryWithId = profileQuery.with(id: DebugHelper.stableId(for: profileQuery))
                let brokerId = DebugHelper.stableId(for: resolvedBroker)
                let profileQueryId = DebugHelper.stableId(for: queryWithId)
                let fakeScanJob = ScanJobData(
                    brokerId: brokerId,
                    profileQueryId: profileQueryId,
                    historyEvents: []
                )
                let queryData = BrokerProfileQueryData(
                    dataBroker: resolvedBroker,
                    profileQuery: queryWithId,
                    scanJobData: fakeScanJob
                )

                let stageCalculator = session.makeStageCalculator()
                let runner = BrokerProfileScanSubJobWebRunner(
                    privacyConfig: mcpJobDependencies.privacyConfig,
                    prefs: mcpJobDependencies.contentScopeProperties,
                    context: queryData,
                    emailConfirmationDataService: emailService,
                    captchaService: debugCaptchaService,
                    featureFlagger: mcpJobDependencies.featureFlagger,
                    applicationNameForUserAgent: mcpJobDependencies.applicationNameForUserAgent,
                    stageDurationCalculator: stageCalculator,
                    pixelHandler: debugPixelHandler,
                    executionConfig: .init(),
                    shouldRunNextStep: { true }
                )
                runner.keepWebViewAlive = pauseOnError

                do {
                    let profiles = try await runner.scan(queryData, showWebView: showWebView) { true }

                    let assignedProfiles: [ExtractedProfile] = profiles.map { profile in
                        session.debugEmailConfirmationStore.storeExtractedProfile(
                            profile,
                            brokerId: brokerId,
                            profileQueryId: profileQueryId,
                            stableId: DebugHelper.stableId(for: profile)
                        )
                    }
                    allExtracted.append(contentsOf: assignedProfiles)

                    await runner.webViewHandler?.finish()
                } catch {
                    session.activeWebViewHandler = runner.webViewHandler
                    throw error
                }
            }

            session.updateState { s in
                s.isRunning = false
                s.currentStep = "idle"
                s.lastBroker = resolvedBroker
                s.lastProfileQuery = profile.profileQueries.first
                s.lastExtractedProfiles = allExtracted
            }
            await removeDebugSession(session)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let result: [String: Any] = [
                "success": true,
                "sessionId": session.id,
                "matchCount": allExtracted.count,
                "extractedProfiles": (try? JSONSerialization.jsonObject(with: encoder.encode(allExtracted))) ?? [],
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])

        } catch {
            Logger.dataBrokerProtection.error("Debug scan failed: \(error.localizedDescription, privacy: .public)")
            session.updateState { s in
                s.isRunning = false
                s.currentStep = "paused"
                s.lastError = error.localizedDescription
            }
            let keepAlive = pauseOnError && session.activeWebViewHandler != nil
            if !keepAlive {
                await removeDebugSession(session)
            }
            let result: [String: Any] = [
                "success": false,
                "sessionId": session.id,
                "error": error.localizedDescription,
                "webViewAlive": keepAlive,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func runCustomOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        let session = createDebugSession()
        let emailService = makeDebugEmailConfirmationService(for: session)
        session.updateState { s in
            s.isRunning = true
            s.currentStep = "optOut"
            s.currentAction = nil
            s.lastError = nil
            s.debugEvents.removeAll()
        }

        do {
            let broker = try JSONDecoder().decode(DataBroker.self, from: brokerJSON)
            let resolvedBroker = broker.with(id: DebugHelper.stableId(for: broker))
            let extractedProfile = try JSONDecoder().decode(ExtractedProfile.self, from: extractedProfileJSON)

            let profile = DataBrokerProtectionProfile(
                names: [.init(firstName: firstName, lastName: lastName, middleName: middleName)],
                addresses: [.init(city: city, state: state)],
                phones: [],
                birthYear: birthYear
            )

            guard let profileQuery = profile.profileQueries.first else {
                throw NSError(domain: "DebugScan", code: -1, userInfo: [NSLocalizedDescriptionKey: "No profile queries generated"])
            }

            let queryWithId = profileQuery.with(id: DebugHelper.stableId(for: profileQuery))
            let fakeScanJob = ScanJobData(
                brokerId: DebugHelper.stableId(for: resolvedBroker),
                profileQueryId: DebugHelper.stableId(for: queryWithId),
                historyEvents: []
            )
            let queryData = BrokerProfileQueryData(
                dataBroker: resolvedBroker,
                profileQuery: queryWithId,
                scanJobData: fakeScanJob
            )

            let stageCalculator = session.makeStageCalculator()
            let runner = BrokerProfileOptOutSubJobWebRunner(
                privacyConfig: mcpJobDependencies.privacyConfig,
                prefs: mcpJobDependencies.contentScopeProperties,
                context: queryData,
                emailConfirmationDataService: emailService,
                captchaService: debugCaptchaService,
                featureFlagger: mcpJobDependencies.featureFlagger,
                applicationNameForUserAgent: mcpJobDependencies.applicationNameForUserAgent,
                stageCalculator: stageCalculator,
                pixelHandler: debugPixelHandler,
                executionConfig: .init(),
                actionsHandlerMode: .optOut,
                shouldRunNextStep: { true }
            )
            runner.keepWebViewAlive = pauseOnError

            session.updateState { s in
                s.lastOptOutExtractedProfile = extractedProfile
            }

            do {
                try await runner.optOut(
                    profileQuery: queryData,
                    extractedProfile: extractedProfile,
                    showWebView: showWebView
                ) { true }

                await runner.webViewHandler?.finish()
            } catch {
                if pauseOnError {
                    session.activeWebViewHandler = runner.webViewHandler
                }
                throw error
            }

            session.updateState { s in
                s.isRunning = false
                s.currentStep = "idle"
            }
            await removeDebugSession(session)

            let result: [String: Any] = [
                "success": true,
                "sessionId": session.id,
                "message": "Opt-out completed successfully.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])

        } catch {
            Logger.dataBrokerProtection.error("Debug opt-out failed: \(error.localizedDescription, privacy: .public)")
            session.updateState { s in
                s.isRunning = false
                s.currentStep = "paused"
                s.lastError = error.localizedDescription
            }
            let keepAlive = pauseOnError && session.activeWebViewHandler != nil
            if !keepAlive {
                await removeDebugSession(session)
            }
            let result: [String: Any] = [
                "success": false,
                "sessionId": session.id,
                "error": error.localizedDescription,
                "webViewAlive": keepAlive,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func getWebViewState(sessionId: String?) async -> Data? {
        guard let session = debugSession(for: sessionId) else {
            let result: [String: Any] = ["success": false, "error": "No active debug session found." + (sessionId != nil ? " Session '\(sessionId!)' not found." : "")]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        return await session.serializeState()
    }

    public func executeJavaScript(sessionId: String?, code: String) async -> Data? {
        guard let session = debugSession(for: sessionId) else {
            let result: [String: Any] = ["success": false, "error": "No active debug session found." + (sessionId != nil ? " Session '\(sessionId!)' not found." : "")]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        guard let handler = session.activeWebViewHandler else {
            let result: [String: Any] = [
                "success": false,
                "error": "No active WebView in session '\(session.id)'. WebView is only kept alive on error with pause_on_error: true.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        do {
            let jsResult = try await handler.evaluateJavaScriptReturningResult(code)
            var result: [String: Any] = ["success": true, "sessionId": session.id]
            if let stringResult = jsResult as? String {
                result["result"] = stringResult
            } else if let numResult = jsResult as? NSNumber {
                result["result"] = numResult
            } else if let boolResult = jsResult as? Bool {
                result["result"] = boolResult
            } else if jsResult == nil || jsResult is NSNull {
                result["result"] = NSNull()
            } else {
                result["result"] = String(describing: jsResult)
            }
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func checkEmailConfirmation(sessionId: String?) async -> Data? {
        guard let session = debugSession(for: sessionId) else {
            let result: [String: Any] = ["success": false, "error": "No active debug session found." + (sessionId != nil ? " Session '\(sessionId!)' not found." : "")]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        let emailService = makeDebugEmailConfirmationService(for: session)
        do {
            try await emailService.checkForEmailConfirmationData()

            let store = session.debugEmailConfirmationStore
            let withLinks = try store.fetchOptOutEmailConfirmationsWithLink()
            let awaiting = try store.fetchOptOutEmailConfirmationsAwaitingLink()

            let result: [String: Any] = [
                "success": true,
                "sessionId": session.id,
                "confirmationsWithLink": withLinks.count,
                "confirmationsAwaiting": awaiting.count,
                "message": withLinks.isEmpty
                    ? "No confirmation links found yet. Try again later."
                    : "Found \(withLinks.count) confirmation link(s). Use continue_optout to complete the opt-out.",
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            let result: [String: Any] = [
                "success": false,
                "error": error.localizedDescription,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    public func closeDebugSession(sessionId: String) async -> Data? {
        guard let session = debugSession(for: sessionId) else {
            let result: [String: Any] = ["success": false, "error": "Session '\(sessionId)' not found."]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
        await removeDebugSession(session)
        let result: [String: Any] = ["success": true, "message": "Session '\(sessionId)' closed."]
        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    public func continueOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, sessionId: String?, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        let originalSession = debugSession(for: sessionId)
        let emailStore = originalSession?.debugEmailConfirmationStore ?? DebugEmailConfirmationStore()

        guard let broker = try? JSONDecoder().decode(DataBroker.self, from: brokerJSON) else {
            let result: [String: Any] = ["success": false, "error": "Invalid broker JSON"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        guard let extractedProfile = try? JSONDecoder().decode(ExtractedProfile.self, from: extractedProfileJSON),
              let extractedProfileId = extractedProfile.id else {
            let result: [String: Any] = ["success": false, "error": "Invalid extracted profile or missing ID"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        let resolvedBroker = broker.with(id: DebugHelper.stableId(for: broker))
        let profile = DataBrokerProtectionProfile(
            names: [.init(firstName: firstName, lastName: lastName, middleName: middleName)],
            addresses: [.init(city: city, state: state)],
            phones: [],
            birthYear: birthYear
        )
        guard let profileQuery = profile.profileQueries.first else {
            let result: [String: Any] = ["success": false, "error": "No profile queries generated"]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        let brokerId = DebugHelper.stableId(for: resolvedBroker)
        let profileQueryId = DebugHelper.stableId(for: profileQuery)

        guard let confirmations = try? emailStore.fetchOptOutEmailConfirmationsWithLink(),
              let match = confirmations.first(where: { $0.brokerId == brokerId && $0.profileQueryId == profileQueryId && $0.extractedProfileId == extractedProfileId }),
              let link = match.emailConfirmationLink,
              let confirmationURL = URL(string: link) else {
            let result: [String: Any] = ["success": false, "error": "No confirmation link found. Run check_email_confirmation first."]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }

        let session = createDebugSession()
        let emailService = makeDebugEmailConfirmationService(for: session)
        session.updateState { s in
            s.isRunning = true
            s.currentStep = "emailConfirmation"
            s.currentAction = nil
            s.lastError = nil
            s.debugEvents.removeAll()
        }

        do {
            let queryWithId = profileQuery.with(id: profileQueryId)
            let fakeScanJob = ScanJobData(brokerId: brokerId, profileQueryId: profileQueryId, historyEvents: [])
            let queryData = BrokerProfileQueryData(dataBroker: resolvedBroker, profileQuery: queryWithId, scanJobData: fakeScanJob)

            let stageCalculator = session.makeStageCalculator()
            let runner = BrokerProfileOptOutSubJobWebRunner(
                privacyConfig: mcpJobDependencies.privacyConfig,
                prefs: mcpJobDependencies.contentScopeProperties,
                context: queryData,
                emailConfirmationDataService: emailService,
                captchaService: debugCaptchaService,
                featureFlagger: mcpJobDependencies.featureFlagger,
                applicationNameForUserAgent: mcpJobDependencies.applicationNameForUserAgent,
                stageCalculator: stageCalculator,
                pixelHandler: debugPixelHandler,
                executionConfig: .init(),
                actionsHandlerMode: .emailConfirmation(confirmationURL),
                shouldRunNextStep: { true }
            )
            runner.keepWebViewAlive = pauseOnError

            do {
                try await runner.optOut(profileQuery: queryData, extractedProfile: extractedProfile, showWebView: showWebView) { true }
                await runner.webViewHandler?.finish()
            } catch {
                if pauseOnError {
                    session.activeWebViewHandler = runner.webViewHandler
                }
                throw error
            }

            session.updateState { s in
                s.isRunning = false
                s.currentStep = "idle"
            }
            await removeDebugSession(session)

            let result: [String: Any] = ["success": true, "sessionId": session.id, "message": "Opt-out email confirmation completed successfully."]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        } catch {
            Logger.dataBrokerProtection.error("Debug email confirmation opt-out failed: \(error.localizedDescription, privacy: .public)")
            session.updateState { s in
                s.isRunning = false
                s.currentStep = pauseOnError ? "paused" : "idle"
                s.lastError = error.localizedDescription
            }
            let keepAlive = pauseOnError && session.activeWebViewHandler != nil
            if !keepAlive {
                await removeDebugSession(session)
            }
            let result: [String: Any] = [
                "success": false,
                "sessionId": session.id,
                "error": error.localizedDescription,
                "webViewAlive": keepAlive,
            ]
            return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        }
    }

    // MARK: - Private Helpers

    private func serializeHistoryEvent(_ event: HistoryEvent, formatter: ISO8601DateFormatter) -> [String: Any] {
        var dict: [String: Any] = [
            "date": formatter.string(from: event.date),
        ]
        if let extractedProfileId = event.extractedProfileId {
            dict["extractedProfileId"] = extractedProfileId
        }
        switch event.type {
        case .scanStarted: dict["type"] = "scanStarted"
        case .noMatchFound: dict["type"] = "noMatchFound"
        case .matchesFound(let count):
            dict["type"] = "matchesFound"
            dict["matchCount"] = count
        case .optOutStarted: dict["type"] = "optOutStarted"
        case .optOutRequested: dict["type"] = "optOutRequested"
        case .optOutConfirmed: dict["type"] = "optOutConfirmed"
        case .optOutSubmittedAndAwaitingEmailConfirmation: dict["type"] = "awaitingEmailConfirmation"
        case .error:
            dict["type"] = "error"
            if let error = event.error { dict["error"] = error }
        case .reAppearence: dict["type"] = "reAppearance"
        case .matchRemovedByUser: dict["type"] = "matchRemovedByUser"
        }
        return dict
    }

    private func serializeHistoryEvents(_ events: [HistoryEvent]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let eventDicts: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "date": formatter.string(from: event.date),
                "brokerId": event.brokerId,
                "profileQueryId": event.profileQueryId,
            ]
            if let extractedProfileId = event.extractedProfileId {
                dict["extractedProfileId"] = extractedProfileId
            }
            switch event.type {
            case .scanStarted: dict["type"] = "scanStarted"
            case .noMatchFound: dict["type"] = "noMatchFound"
            case .matchesFound(let count):
                dict["type"] = "matchesFound"
                dict["matchCount"] = count
            case .optOutStarted: dict["type"] = "optOutStarted"
            case .optOutRequested: dict["type"] = "optOutRequested"
            case .optOutConfirmed: dict["type"] = "optOutConfirmed"
            case .optOutSubmittedAndAwaitingEmailConfirmation: dict["type"] = "awaitingEmailConfirmation"
            case .error:
                dict["type"] = "error"
                if let error = event.error { dict["error"] = error }
            case .reAppearence: dict["type"] = "reAppearance"
            case .matchRemovedByUser: dict["type"] = "matchRemovedByUser"
            }
            return dict
        }

        return try JSONSerialization.data(withJSONObject: eventDicts, options: [.prettyPrinted, .sortedKeys])
    }
}
