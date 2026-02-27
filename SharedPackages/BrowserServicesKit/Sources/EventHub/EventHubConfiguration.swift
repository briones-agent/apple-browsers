//
//  EventHubConfiguration.swift
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

public struct EventHubConfiguration: Equatable, Codable {
    public let state: String
    public let telemetry: [String: TelemetryPixelConfiguration]

    public var isEnabled: Bool {
        state == "enabled"
    }

    public init(state: String, telemetry: [String: TelemetryPixelConfiguration]) {
        self.state = state
        self.telemetry = telemetry
    }

    public init?(settings: [String: Any]) {
        guard let state = settings["state"] as? String else { return nil }

        self.state = state
        var telemetry: [String: TelemetryPixelConfiguration] = [:]
        if let telemetryDict = settings["telemetry"] as? [String: [String: Any]] {
            for (name, config) in telemetryDict {
                if let parsed = TelemetryPixelConfiguration(json: config) {
                    telemetry[name] = parsed
                }
            }
        }
        self.telemetry = telemetry
    }
}

public struct TelemetryPixelConfiguration: Equatable, Codable {
    public let state: String
    public let trigger: TriggerConfiguration
    public let parameters: [String: ParameterConfiguration]

    public var isEnabled: Bool {
        state == "enabled"
    }

    public init(state: String, trigger: TriggerConfiguration, parameters: [String: ParameterConfiguration]) {
        self.state = state
        self.trigger = trigger
        self.parameters = parameters
    }

    public init?(json: [String: Any]) {
        guard let state = json["state"] as? String,
              let triggerDict = json["trigger"] as? [String: Any],
              let trigger = TriggerConfiguration(json: triggerDict) else {
            return nil
        }

        self.state = state
        self.trigger = trigger

        var parameters: [String: ParameterConfiguration] = [:]
        if let paramsDict = json["parameters"] as? [String: [String: Any]] {
            for (name, config) in paramsDict {
                if let parsed = ParameterConfiguration(json: config) {
                    parameters[name] = parsed
                }
            }
        }
        self.parameters = parameters
    }
}

public struct TriggerConfiguration: Equatable, Codable {
    public let period: PeriodConfiguration

    public init(period: PeriodConfiguration) {
        self.period = period
    }

    public init?(json: [String: Any]) {
        guard let periodDict = json["period"] as? [String: Any],
              let period = PeriodConfiguration(json: periodDict) else {
            return nil
        }
        self.period = period
    }
}

public struct PeriodConfiguration: Equatable, Codable {
    public let seconds: Int
    public let minutes: Int
    public let hours: Int
    public let days: Int

    public var totalSeconds: TimeInterval {
        TimeInterval(seconds + minutes * 60 + hours * 3600 + days * 86400)
    }

    public init(seconds: Int = 0, minutes: Int = 0, hours: Int = 0, days: Int = 0) {
        self.seconds = seconds
        self.minutes = minutes
        self.hours = hours
        self.days = days
    }

    public init?(json: [String: Any]) {
        self.seconds = json["seconds"] as? Int ?? 0
        self.minutes = json["minutes"] as? Int ?? 0
        self.hours = json["hours"] as? Int ?? 0
        self.days = json["days"] as? Int ?? 0

        guard totalSeconds > 0 else { return nil }
    }
}

public struct ParameterConfiguration: Equatable, Codable {
    public let template: String
    public let source: String
    public let buckets: [String: BucketConfiguration]

    public init(template: String, source: String, buckets: [String: BucketConfiguration]) {
        self.template = template
        self.source = source
        self.buckets = buckets
    }

    public init?(json: [String: Any]) {
        guard let template = json["template"] as? String,
              let source = json["source"] as? String else {
            return nil
        }
        self.template = template
        self.source = source

        var buckets: [String: BucketConfiguration] = [:]
        if let bucketsDict = json["buckets"] as? [String: [String: Any]] {
            for (name, config) in bucketsDict {
                if let parsed = BucketConfiguration(json: config) {
                    buckets[name] = parsed
                }
            }
        }
        self.buckets = buckets
    }
}

public struct BucketConfiguration: Equatable, Codable {
    public let gte: Int
    public let lt: Int?

    public init(gte: Int, lt: Int? = nil) {
        self.gte = gte
        self.lt = lt
    }

    public init?(json: [String: Any]) {
        guard let gte = json["gte"] as? Int else { return nil }
        self.gte = gte
        self.lt = json["lt"] as? Int
    }
}
