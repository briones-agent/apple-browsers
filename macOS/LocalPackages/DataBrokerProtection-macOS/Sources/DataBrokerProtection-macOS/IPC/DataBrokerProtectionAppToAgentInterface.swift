//
//  DataBrokerProtectionAppToAgentInterface.swift
//
//  Copyright © 2023 DuckDuckGo. All rights reserved.
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

public enum DataBrokerProtectionAppToAgentInterfaceError: Error {
    case loginItemDoesNotHaveNecessaryPermissions
    case appInWrongDirectory
}

public protocol DataBrokerProtectionAgentAppEvents {
    func profileSaved() async
    func appLaunched() async
}

public protocol DataBrokerProtectionAgentDebugCommands {
    func openBrowser(domain: String)
    func startImmediateOperations(showWebView: Bool)
    func startScheduledOperations(showWebView: Bool)
    func runAllOptOuts(showWebView: Bool)
    func checkForEmailConfirmationData() async
    func runEmailConfirmationOperations(showWebView: Bool) async
    func getDebugMetadata() async -> DBPBackgroundAgentMetadata?

    // MARK: - MCP Debug Server Support (Read-Only)

    /// Returns JSON-encoded broker profile query data for all brokers.
    func getBrokerProfileData() async -> Data?
    /// Returns JSON-encoded broker definition for a specific broker by URL.
    func getBrokerJSON(brokerURL: String) async -> Data?
    /// Returns detailed per-profile-query data for a specific broker.
    func getBrokerDetails(brokerName: String) async -> Data?
    /// Returns scheduler state with optional history events filtered by type (scan/optout/all).
    func getSchedulerState(brokerName: String, profileQueryId: Int64, extractedProfileId: Int64, historyType: String?) async -> Data?
    /// Returns auth/subscription status info.
    func getAuthStatus() async -> Data?

    // MARK: - MCP Debug Server Support (Actions)

    /// Removes all PIR data from the encrypted database.
    func removeAllData() async -> Data?
    /// Saves (upserts) a profile from JSON.
    func saveProfile(profileJSON: Data) async -> Data?
    /// Forces broker JSON update, bypassing the hourly rate limiter.
    func forceBrokerUpdate() async -> Data?
    /// Sets the API environment and optional service root path.
    func setAPIEndpoint(environment: String, serviceRoot: String) async -> Data?

    /// Runs a custom scan with broker JSON and profile info. Returns extracted profiles as JSON.
    func runCustomScan(brokerJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data?
    /// Runs opt-out for an extracted profile from a previous scan. Takes broker JSON + extracted profile JSON.
    func runCustomOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data?
    /// Returns the current debug WebView state (action progress, errors, etc.)
    func getWebViewState(sessionId: String?) async -> Data?
    /// Signs out of subscription and opens the activation flow for the user to re-auth.
    func reauthenticate() async -> Data?
    /// Evaluates JavaScript on the paused debug WebView.
    func executeJavaScript(sessionId: String?, code: String) async -> Data?
    /// Checks for email confirmation links from the backend.
    func checkEmailConfirmation(sessionId: String?) async -> Data?
    /// Closes a debug session and releases its WebView.
    func closeDebugSession(sessionId: String) async -> Data?
    /// Continues opt-out after email confirmation link is found.
    func continueOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, middleName: String?, city: String, state: String, birthYear: Int, sessionId: String?, showWebView: Bool, pauseOnError: Bool) async -> Data?
}

public protocol DataBrokerProtectionAppToAgentInterface: AnyObject, DataBrokerProtectionAgentAppEvents, DataBrokerProtectionAgentDebugCommands {

}
