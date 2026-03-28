//
//  DataBrokerProtectionIPCClient.swift
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

import Combine
import Common
import Foundation
import XPCHelper
import os.log

/// This protocol describes the server-side IPC interface for controlling the tunnel
///
public protocol IPCClientInterface: AnyObject {
}

public protocol DBPLoginItemStatusChecker {
    func doesHaveNecessaryPermissions() -> Bool
    func isInCorrectDirectory() -> Bool
}

/// This is the XPC interface with parameters that can be packed properly
@objc
protocol XPCClientInterface: NSObjectProtocol {
}

public final class DataBrokerProtectionIPCClient: NSObject {

    private let pixelHandler: EventMapping<DataBrokerProtectionMacOSPixels>
    private let loginItemStatusChecker: DBPLoginItemStatusChecker

    // MARK: - XPC Communication

    let xpc: XPCClient<XPCClientInterface, XPCServerInterface>

    // MARK: - Initializers

    public init(machServiceName: String, pixelHandler: EventMapping<DataBrokerProtectionMacOSPixels>, loginItemStatusChecker: DBPLoginItemStatusChecker) {
        self.pixelHandler = pixelHandler
        self.loginItemStatusChecker = loginItemStatusChecker
        let clientInterface = NSXPCInterface(with: XPCClientInterface.self)
        let serverInterface = NSXPCInterface(with: XPCServerInterface.self)

        xpc = XPCClient(
            machServiceName: machServiceName,
            clientInterface: clientInterface,
            serverInterface: serverInterface)

        super.init()

        xpc.delegate = self
        xpc.onDisconnect = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                try await Task.sleep(interval: .seconds(1))
                // By calling register we make sure that XPC will connect as soon as it
                // becomes available again, as requests are queued.  This helps ensure
                // that the client app will always be connected to XPC.
                self.register()
            }
        }

        self.register()
    }
}

// MARK: - Outgoing communication to the server

extension DataBrokerProtectionIPCClient: IPCServerInterface {

    public func register() {
        xpc.execute(call: { server in
            server.register()
        }, xpcReplyErrorHandler: { _ in
            // Intentional no-op as there's no completion block
            // If you add a completion block, please remember to call it here too!
        })
    }

    // MARK: - DataBrokerProtectionAgentAppEvents

    public func profileSaved(xpcMessageReceivedCompletion: @escaping (Error?) -> Void) {
        xpc.execute(call: { server in
            server.profileSaved(xpcMessageReceivedCompletion: xpcMessageReceivedCompletion)
        }, xpcReplyErrorHandler: xpcMessageReceivedCompletion)
    }

    public func appLaunched(xpcMessageReceivedCompletion: @escaping (Error?) -> Void) {
        xpc.execute(call: { server in
            server.appLaunched(xpcMessageReceivedCompletion: xpcMessageReceivedCompletion)
        }, xpcReplyErrorHandler: xpcMessageReceivedCompletion)
    }

    // MARK: - DataBrokerProtectionAgentDebugCommands

    public func openBrowser(domain: String) {
        xpc.execute(call: { server in
            server.openBrowser(domain: domain)
        }, xpcReplyErrorHandler: { error in
            Logger.dataBrokerProtection.error("Error \(error.localizedDescription)")
            // Intentional no-op as there's no completion block
            // If you add a completion block, please remember to call it here too!
        })
    }

    public func startImmediateOperations(showWebView: Bool) {
        xpc.execute(call: { server in
            server.startImmediateOperations(showWebView: showWebView)
        }, xpcReplyErrorHandler: { error in
            Logger.dataBrokerProtection.error("Error \(error.localizedDescription)")
            // Intentional no-op as there's no completion block
            // If you add a completion block, please remember to call it here too!
        })
    }

    public func startScheduledOperations(showWebView: Bool) {
        xpc.execute(call: { server in
            server.startScheduledOperations(showWebView: showWebView)
        }, xpcReplyErrorHandler: { error in
            Logger.dataBrokerProtection.error("Error \(error.localizedDescription)")
            // Intentional no-op as there's no completion block
            // If you add a completion block, please remember to call it here too!
        })
    }

    public func runAllOptOuts(showWebView: Bool) {
        xpc.execute(call: { server in
            server.runAllOptOuts(showWebView: showWebView)
        }, xpcReplyErrorHandler: { error in
            Logger.dataBrokerProtection.error("Error \(error.localizedDescription)")
            // Intentional no-op as there's no completion block
            // If you add a completion block, please remember to call it here too!
        })
    }

    public func checkForEmailConfirmationData() {
        xpc.execute(call: { server in
            server.checkForEmailConfirmationData()
        }, xpcReplyErrorHandler: { error in
            Logger.dataBrokerProtection.error("Error checking for email confirmation data: \(error.localizedDescription)")
            // Intentional no-op as there's no completion block
            // If you add a completion block, please remember to call it here too!
        })
    }

    public func runEmailConfirmationOperations(showWebView: Bool) {
        xpc.execute(call: { server in
            server.runEmailConfirmationOperations(showWebView: showWebView)
        }, xpcReplyErrorHandler: { error in
            Logger.dataBrokerProtection.error("Error running email confirmation operations: \(error.localizedDescription)")
            // Intentional no-op as there's no completion block
            // If you add a completion block, please remember to call it here too!
        })
    }

    public func getDebugMetadata() async -> DBPBackgroundAgentMetadata? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getDebugMetadata { metaData in
                    continuation.resume(returning: metaData)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    // MARK: - MCP Debug Server Support (Read-Only)

    public func getBrokerProfileData() async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getBrokerProfileData { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error fetching broker profile data: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func getBrokerJSON(brokerURL: String) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getBrokerJSON(brokerURL: brokerURL) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error fetching broker JSON: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func getBrokerDetails(brokerName: String) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getBrokerDetails(brokerName: brokerName) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error fetching broker details: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func getScanHistory(brokerId: Int64, profileQueryId: Int64) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getScanHistory(brokerId: brokerId, profileQueryId: profileQueryId) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error fetching scan history: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func getOptOutHistory(brokerId: Int64, profileQueryId: Int64, extractedProfileId: Int64) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getOptOutHistory(brokerId: brokerId, profileQueryId: profileQueryId, extractedProfileId: extractedProfileId) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error fetching opt-out history: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func getAuthStatus() async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getAuthStatus { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error fetching auth status: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    // MARK: - MCP Debug Server Support (Actions)

    public func forceBrokerUpdate() async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.forceBrokerUpdate { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error forcing broker update: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func setAPIEndpoint(environment: String, serviceRoot: String) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.setAPIEndpoint(environment: environment, serviceRoot: serviceRoot) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error setting API endpoint: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func runCustomScan(brokerJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.runCustomScan(brokerJSON: brokerJSON, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error running custom scan: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func runCustomOptOut(brokerJSON: Data, extractedProfileJSON: Data, firstName: String, lastName: String, city: String, state: String, birthYear: Int, showWebView: Bool, pauseOnError: Bool) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.runCustomOptOut(brokerJSON: brokerJSON, extractedProfileJSON: extractedProfileJSON, firstName: firstName, lastName: lastName, city: city, state: state, birthYear: birthYear, showWebView: showWebView, pauseOnError: pauseOnError) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error running custom opt-out: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func getWebViewState() async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.getWebViewState { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error getting WebView state: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func reauthenticate() async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.reauthenticate { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error reauthenticating: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }

    public func executeJavaScript(code: String) async -> Data? {
        await withCheckedContinuation { continuation in
            xpc.execute(call: { server in
                server.executeJavaScript(code: code) { data in
                    continuation.resume(returning: data)
                }
            }, xpcReplyErrorHandler: { error in
                Logger.dataBrokerProtection.error("Error executing JavaScript: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
        }
    }
}

// MARK: - Incoming communication from the server

extension DataBrokerProtectionIPCClient: XPCClientInterface {
}
