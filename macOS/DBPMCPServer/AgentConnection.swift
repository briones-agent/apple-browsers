//
//  AgentConnection.swift
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

// MARK: - XPC Protocol Mirrors

/// Mirror of the agent's XPC server interface.
/// Duplicated here to avoid linking the full DataBrokerProtection framework.
@objc protocol DBPXPCServerInterface {
    func register()
    func startImmediateOperations(showWebView: Bool)
    func getDebugMetadata(completion: @escaping (DBPAgentMetadata?) -> Void)
    func getBrokerProfileData(completion: @escaping (Data?) -> Void)
    func getBrokerJSON(brokerURL: String, completion: @escaping (Data?) -> Void)
    func getBrokerDetails(brokerName: String, completion: @escaping (Data?) -> Void)
    func getScanHistory(brokerId: Int64, profileQueryId: Int64, completion: @escaping (Data?) -> Void)
    func getOptOutHistory(brokerId: Int64, profileQueryId: Int64, extractedProfileId: Int64, completion: @escaping (Data?) -> Void)
    func getAuthStatus(completion: @escaping (Data?) -> Void)
    func runCustomScan(brokerJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool, completion: @escaping (Data?) -> Void)
    func forceBrokerUpdate(completion: @escaping (Data?) -> Void)
    func setAPIEndpoint(environment: String, serviceRoot: String, completion: @escaping (Data?) -> Void)
    func runCustomOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool, completion: @escaping (Data?) -> Void)
    func getWebViewState(completion: @escaping (Data?) -> Void)
    func reauthenticate(completion: @escaping (Data?) -> Void)
    func executeJavaScript(code: String, completion: @escaping (Data?) -> Void)
    func checkEmailConfirmation(completion: @escaping (Data?) -> Void)
    func continueOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool, completion: @escaping (Data?) -> Void)
}

/// Mirror of the agent's XPC client interface (currently unused by MCP server).
@objc protocol DBPXPCClientInterface: NSObjectProtocol {
}

/// Mirror of the metadata class the agent returns via XPC.
/// Must use the same @objc name as the original for NSSecureCoding to work across processes.
@objc(DBPBackgroundAgentMetadata)
final class DBPAgentMetadata: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool = true

    let backgroundAgentVersion: String
    let isAgentRunning: Bool
    let agentSchedulerState: String
    let lastSchedulerSessionStartTimestamp: Double?

    override init() {
        self.backgroundAgentVersion = ""
        self.isAgentRunning = false
        self.agentSchedulerState = ""
        self.lastSchedulerSessionStartTimestamp = nil
        super.init()
    }

    init?(coder: NSCoder) {
        guard let version = coder.decodeObject(of: NSString.self, forKey: "backgroundAgentVersion") as? String,
              let state = coder.decodeObject(of: NSString.self, forKey: "agentSchedulerState") as? String else {
            return nil
        }
        self.backgroundAgentVersion = version
        self.isAgentRunning = coder.decodeBool(forKey: "isAgentRunning")
        self.agentSchedulerState = state
        self.lastSchedulerSessionStartTimestamp = coder.decodeObject(of: NSNumber.self, forKey: "lastSchedulerSessionStartTimestamp")?.doubleValue
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(backgroundAgentVersion as NSString, forKey: "backgroundAgentVersion")
        coder.encode(isAgentRunning, forKey: "isAgentRunning")
        coder.encode(agentSchedulerState as NSString, forKey: "agentSchedulerState")
        if let ts = lastSchedulerSessionStartTimestamp {
            coder.encode(ts as NSNumber, forKey: "lastSchedulerSessionStartTimestamp")
        }
    }
}

// MARK: - Agent Connection

/// XPC client that connects to the PIR background agent.
final class AgentConnection: NSObject, DBPXPCClientInterface {
    private let machServiceName: String
    private var connection: NSXPCConnection?

    init(machServiceName: String) {
        self.machServiceName = machServiceName
        super.init()
    }

    // MARK: - Connection Management

    private func ensureConnection() -> NSXPCConnection {
        if let existing = connection {
            return existing
        }

        let conn = NSXPCConnection(machServiceName: machServiceName)

        let clientInterface = NSXPCInterface(with: DBPXPCClientInterface.self)
        let serverInterface = NSXPCInterface(with: DBPXPCServerInterface.self)

        // Allow the metadata class to be decoded in the getDebugMetadata reply
        let allowedClasses = NSSet(object: DBPAgentMetadata.self)
        serverInterface.setClasses(allowedClasses as? Set<AnyHashable> ?? [],
                                   for: #selector(DBPXPCServerInterface.getDebugMetadata(completion:)),
                                   argumentIndex: 0,
                                   ofReply: true)

        conn.exportedInterface = clientInterface
        conn.exportedObject = self
        conn.remoteObjectInterface = serverInterface

        conn.interruptionHandler = { [weak self] in
            log("XPC connection interrupted")
            self?.connection = nil
        }
        conn.invalidationHandler = { [weak self] in
            log("XPC connection invalidated")
            self?.connection = nil
        }

        conn.activate()
        connection = conn

        if let proxy = conn.remoteObjectProxy as? DBPXPCServerInterface {
            proxy.register()
        }

        return conn
    }

    private func serverProxy(errorHandler: @escaping (Error) -> Void) -> DBPXPCServerInterface? {
        let conn = ensureConnection()
        return conn.remoteObjectProxyWithErrorHandler(errorHandler) as? DBPXPCServerInterface
    }

    // MARK: - Public API

    func getDebugMetadata(completion: @escaping (DBPAgentMetadata?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getDebugMetadata): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getDebugMetadata(completion: completion)
    }

    func startImmediateOperations(showWebView: Bool) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (startImmediateOperations): \(error)")
        }) else { return }
        proxy.startImmediateOperations(showWebView: showWebView)
    }

    func getBrokerProfileData(completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getBrokerProfileData): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getBrokerProfileData(completion: completion)
    }

    func getBrokerJSON(brokerURL: String, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getBrokerJSON): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getBrokerJSON(brokerURL: brokerURL, completion: completion)
    }

    func getBrokerDetails(brokerName: String, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getBrokerDetails): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getBrokerDetails(brokerName: brokerName, completion: completion)
    }

    func getScanHistory(brokerId: Int64, profileQueryId: Int64, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getScanHistory): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getScanHistory(brokerId: brokerId, profileQueryId: profileQueryId, completion: completion)
    }

    func getOptOutHistory(brokerId: Int64, profileQueryId: Int64, extractedProfileId: Int64, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getOptOutHistory): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getOptOutHistory(brokerId: brokerId, profileQueryId: profileQueryId, extractedProfileId: extractedProfileId, completion: completion)
    }

    func getAuthStatus(completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getAuthStatus): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getAuthStatus(completion: completion)
    }

    func runCustomScan(brokerJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (runCustomScan): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.runCustomScan(brokerJSON: brokerJSON, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError, completion: completion)
    }

    func forceBrokerUpdate(completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (forceBrokerUpdate): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.forceBrokerUpdate(completion: completion)
    }

    func setAPIEndpoint(environment: String, serviceRoot: String, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (setAPIEndpoint): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.setAPIEndpoint(environment: environment, serviceRoot: serviceRoot, completion: completion)
    }

    func runCustomOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (runCustomOptOut): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.runCustomOptOut(brokerJSON: brokerJSON, extractedProfileJSON: extractedProfileJSON, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError, completion: completion)
    }

    func getWebViewState(completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (getWebViewState): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.getWebViewState(completion: completion)
    }

    func reauthenticate(completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (reauthenticate): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.reauthenticate(completion: completion)
    }

    func executeJavaScript(code: String, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (executeJavaScript): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.executeJavaScript(code: code, completion: completion)
    }

    func checkEmailConfirmation(completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (checkEmailConfirmation): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.checkEmailConfirmation(completion: completion)
    }

    func continueOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool, completion: @escaping (Data?) -> Void) {
        guard let proxy = serverProxy(errorHandler: { error in
            log("XPC error (continueOptOut): \(error)")
            completion(nil)
        }) else {
            completion(nil)
            return
        }
        proxy.continueOptOut(brokerJSON: brokerJSON, extractedProfileJSON: extractedProfileJSON, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError, completion: completion)
    }
}
