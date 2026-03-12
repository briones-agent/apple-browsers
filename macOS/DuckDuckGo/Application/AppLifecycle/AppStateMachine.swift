//
//  AppStateMachine.swift
//  DuckDuckGo
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

import AppKit
import Common
import os.log

// MARK: - Events

enum AppEvent {

    case willFinishLaunching
    case didFinishLaunching
    case appDidFinishLaunching
    case didBecomeActive

}

// MARK: - State

enum AppState {

    case initializing(any InitializingHandling)
    case launching(any LaunchingHandling)
    case foreground(any ForegroundHandling)
    case terminating(any TerminatingHandling)

    var name: String {
        switch self {
        case .initializing:
            return "initializing"
        case .launching:
            return "launching"
        case .foreground:
            return "foreground"
        case .terminating:
            return "terminating"
        }
    }

}

// MARK: - State Protocols

@MainActor
protocol InitializingHandling {

    init()

    func makeLaunchingState() throws -> any LaunchingHandling

}

@MainActor
protocol LaunchingHandling {

    func handleWillFinishLaunching()
    func makeForegroundState() throws -> any ForegroundHandling

}

@MainActor
protocol ForegroundHandling {

    func onTransition()
    func didReturn()
    func handleTerminationRequest(onAsyncTerminationApproved: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply

}

@MainActor
protocol TerminatingHandling {

    init(error: Error)
    init()

    func terminate()

}

// MARK: - Terminating State Factory

@MainActor
protocol TerminatingStateFactory {

    func makeTerminatingState(error: Error) -> any TerminatingHandling
    func makeTerminatingState() -> any TerminatingHandling

}

@MainActor
struct DefaultTerminatingStateFactory: TerminatingStateFactory {

    nonisolated init() {}

    func makeTerminatingState(error: Error) -> any TerminatingHandling {
        Terminating(error: error)
    }

    func makeTerminatingState() -> any TerminatingHandling {
        Terminating()
    }

}

// MARK: - State Machine

@MainActor
final class AppStateMachine {

    private(set) var currentState: AppState
    private let terminatingStateFactory: TerminatingStateFactory

    init(initialState: AppState, terminatingStateFactory: TerminatingStateFactory = DefaultTerminatingStateFactory()) {
        self.currentState = initialState
        self.terminatingStateFactory = terminatingStateFactory
    }

    func handle(_ event: AppEvent) {
        switch currentState {
        case .initializing(let initializing):
            respond(to: event, in: initializing)
        case .launching(let launching):
            respond(to: event, in: launching)
        case .foreground(let foreground):
            respond(to: event, in: foreground)
        case .terminating:
            handleUnexpectedEvent(event)
        }
    }

    func handleTerminationRequest() -> NSApplication.TerminateReply {
        guard case .foreground(let foreground) = currentState else {
            Logger.general.error("Termination request received in unexpected state: \(self.currentState.name)")
            return .terminateCancel
        }
        let reply = foreground.handleTerminationRequest(onAsyncTerminationApproved: { [weak self] in
            self?.confirmTermination()
        })
        if reply == .terminateNow {
            confirmTermination()
        }
        return reply
    }

    private func confirmTermination() {
        guard case .foreground = currentState else {
            Logger.general.error("Async termination confirmation received in unexpected state: \(self.currentState.name)")
            return
        }
        let terminating = terminatingStateFactory.makeTerminatingState()
        terminating.terminate()
        currentState = .terminating(terminating)
    }

    // MARK: - Private

    private func respond(to event: AppEvent, in initializing: any InitializingHandling) {
        switch event {
        case .didFinishLaunching:
            do {
                currentState = try .launching(initializing.makeLaunchingState())
            } catch {
                let terminating = terminatingStateFactory.makeTerminatingState(error: error)
                terminating.terminate()
                currentState = .terminating(terminating)
            }
        default:
            handleUnexpectedEvent(event)
        }
    }

    private func respond(to event: AppEvent, in launching: any LaunchingHandling) {
        switch event {
        case .willFinishLaunching:
            launching.handleWillFinishLaunching()
        case .appDidFinishLaunching:
            do {
                let foreground = try launching.makeForegroundState()
                currentState = .foreground(foreground)
                foreground.onTransition()
            } catch {
                let terminating = terminatingStateFactory.makeTerminatingState(error: error)
                terminating.terminate()
                currentState = .terminating(terminating)
            }
        default:
            handleUnexpectedEvent(event)
        }
    }

    private func respond(to event: AppEvent, in foreground: any ForegroundHandling) {
        switch event {
        case .didBecomeActive:
            foreground.didReturn()
        default:
            handleUnexpectedEvent(event)
        }
    }

    private func handleUnexpectedEvent(_ event: AppEvent) {
        Logger.general.error("Unexpected [\(String(describing: event))] event while in [\(self.currentState.name)] state")
    }

}
