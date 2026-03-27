//
//  DataBrokerProtectionLoginItemInterface.swift
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
import DataBrokerProtection_macOS
import Common

public extension Notification.Name {
    static let dbpLoginItemEnabled = Notification.Name("com.duckduckgo.DBP.LoginItemEnabled")
    static let dbpLoginItemDisabled = Notification.Name("com.duckduckgo.DBP.LoginItemDisabled")
}

protocol DataBrokerProtectionLoginItemInterface: DataBrokerProtectionAppToAgentInterface {
    func dataDeleted()
}

/// Launches a login item and then communicates with it through IPC
///
final class DefaultDataBrokerProtectionLoginItemInterface {
    private let ipcClient: DataBrokerProtectionIPCClient
    private let loginItemsManager: LoginItemsManager
    private let pixelHandler: EventMapping<DataBrokerProtectionMacOSPixels>

    init(ipcClient: DataBrokerProtectionIPCClient,
         loginItemsManager: LoginItemsManager = .init(),
         pixelHandler: EventMapping<DataBrokerProtectionMacOSPixels>) {
        self.ipcClient = ipcClient
        self.loginItemsManager = loginItemsManager
        self.pixelHandler = pixelHandler
    }
}

extension DefaultDataBrokerProtectionLoginItemInterface: DataBrokerProtectionLoginItemInterface {

    // MARK: - Login Item Management

    private func disableLoginItem() {
        DataBrokerProtectionLoginItemPixels.fire(pixel: GeneralPixel.dataBrokerDisableLoginItemDaily, frequency: .legacyDaily)
        loginItemsManager.disableLoginItems([.dbpBackgroundAgent])
        NotificationCenter.default.post(name: .dbpLoginItemDisabled, object: nil)
    }

    private func enableLoginItem() {
        DataBrokerProtectionLoginItemPixels.fire(pixel: GeneralPixel.dataBrokerEnableLoginItemDaily, frequency: .legacyDaily)
        loginItemsManager.enableLoginItems([.dbpBackgroundAgent])
        NotificationCenter.default.post(name: .dbpLoginItemEnabled, object: nil)
    }

    // MARK: - DataBrokerProtectionLoginItemInterface

    func dataDeleted() {
        disableLoginItem()
    }

    // MARK: - DataBrokerProtectionAppToAgentInterface
    // MARK: - DataBrokerProtectionAgentAppEvents

    func profileSaved() {
        enableLoginItem()

        Task {
            // Wait to make sure the agent has had time to launch
            try await Task.sleep(nanoseconds: 1_000_000_000)
            pixelHandler.fire(.ipcServerProfileSavedCalledByApp)
            ipcClient.profileSaved { error in
                if let error = error {
                    self.pixelHandler.fire(.ipcServerProfileSavedXPCError(error: error))
                } else {
                    self.pixelHandler.fire(.ipcServerProfileSavedReceivedByAgent)
                }
            }
        }
    }

    func appLaunched() {
        pixelHandler.fire(.ipcServerAppLaunchedCalledByApp)
        ipcClient.appLaunched { error in
            if let error = error {
                self.pixelHandler.fire(.ipcServerAppLaunchedXPCError(error: error))
            } else {
                self.pixelHandler.fire(.ipcServerAppLaunchedReceivedByAgent)
            }
        }
    }

    // MARK: - DataBrokerProtectionAgentDebugCommands

    func openBrowser(domain: String) {
        ipcClient.openBrowser(domain: domain)
    }

    func startImmediateOperations(showWebView: Bool) {
        ipcClient.startImmediateOperations(showWebView: showWebView)
    }

    func startScheduledOperations(showWebView: Bool) {
        ipcClient.startScheduledOperations(showWebView: showWebView)
    }

    func runAllOptOuts(showWebView: Bool) {
        ipcClient.runAllOptOuts(showWebView: showWebView)
    }

    func checkForEmailConfirmationData() {
        ipcClient.checkForEmailConfirmationData()
    }

    func runEmailConfirmationOperations(showWebView: Bool) {
        ipcClient.runEmailConfirmationOperations(showWebView: showWebView)
    }

    func getDebugMetadata() async -> DBPBackgroundAgentMetadata? {
        return await ipcClient.getDebugMetadata()
    }

    // MARK: - MCP Debug Server Support (Read-Only)

    func getBrokerProfileData() async -> Data? {
        return await ipcClient.getBrokerProfileData()
    }

    func getBrokerJSON(brokerURL: String) async -> Data? {
        return await ipcClient.getBrokerJSON(brokerURL: brokerURL)
    }

    func getBrokerDetails(brokerName: String) async -> Data? {
        return await ipcClient.getBrokerDetails(brokerName: brokerName)
    }

    func getScanHistory(brokerId: Int64, profileQueryId: Int64) async -> Data? {
        return await ipcClient.getScanHistory(brokerId: brokerId, profileQueryId: profileQueryId)
    }

    func getOptOutHistory(brokerId: Int64, profileQueryId: Int64, extractedProfileId: Int64) async -> Data? {
        return await ipcClient.getOptOutHistory(brokerId: brokerId, profileQueryId: profileQueryId, extractedProfileId: extractedProfileId)
    }

    func getAuthStatus() async -> Data? {
        return await ipcClient.getAuthStatus()
    }

    // MARK: - MCP Debug Server Support (Actions)

    func forceBrokerUpdate() async -> Data? {
        return await ipcClient.forceBrokerUpdate()
    }

    func setAPIEndpoint(environment: String, serviceRoot: String) async -> Data? {
        return await ipcClient.setAPIEndpoint(environment: environment, serviceRoot: serviceRoot)
    }

    func runCustomScan(brokerJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool) async -> Data? {
        return await ipcClient.runCustomScan(brokerJSON: brokerJSON, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView)
    }

    func runCustomOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool) async -> Data? {
        return await ipcClient.runCustomOptOut(brokerJSON: brokerJSON, extractedProfileJSON: extractedProfileJSON, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView)
    }

    func getWebViewState() async -> Data? {
        return await ipcClient.getWebViewState()
    }
}
