//
//  ScheduledFuture.swift
//
//  Copyright © 2021 DuckDuckGo. All rights reserved.
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
import Combine

public final class ScheduledFuture<Output: Sendable, Failure: Error & Sendable>: Publisher {

    private var future: Future<Output, Failure>

    public init(
        scheduler: DispatchQueue,
        _ attemptToFulfill: @escaping @Sendable (@escaping Future<Output, Failure>.Promise) -> Void
    ) {
        future = Future<Output, Failure> { promise in
            let promise = SendablePromise(promise)
            scheduler.async {
                attemptToFulfill(promise.callAsFunction)
            }
        }
    }

    public func receive<Downstream: Subscriber>(subscriber: Downstream)
        where Output == Downstream.Input, Failure == Downstream.Failure {
        future.receive(subscriber: subscriber)
    }

}

private struct SendablePromise<Output: Sendable, Failure: Error & Sendable>: @unchecked Sendable {

    private let promise: Future<Output, Failure>.Promise

    init(_ promise: @escaping Future<Output, Failure>.Promise) {
        self.promise = promise
    }

    func callAsFunction(_ result: Result<Output, Failure>) {
        promise(result)
    }

}
