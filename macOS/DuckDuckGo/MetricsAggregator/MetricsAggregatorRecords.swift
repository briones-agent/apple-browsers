//
//  MetricsAggregatorRecords.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
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
import GRDB

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

struct PixelConfig: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pixel_config"

    let pixel: String
    var aggregationInterval: Double

    enum CodingKeys: String, CodingKey {
        case pixel
        case aggregationInterval = "aggregation_interval"
    }
}

struct MetricBucket: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "metric_buckets"

    var id: Int64?
    let pixel: String
    let metricName: String
    let ordinal: Int
    let minInclusive: Double
    let maxExclusive: Double?
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case pixel
        case metricName = "metric_name"
        case ordinal
        case minInclusive = "min_inclusive"
        case maxExclusive = "max_exclusive"
        case name
    }
}

struct AggregatedMetric: FetchableRecord, PersistableRecord {
    static let databaseTableName = "aggregated_metrics"

    var id: Int64?
    let pixel: String
    let metricType: String
    let metricName: String
    var value: Double
    var createdAt: Date
    var updatedAt: Date

    init(id: Int64? = nil, pixel: String, metricType: String, metricName: String, value: Double, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.pixel = pixel
        self.metricType = metricType
        self.metricName = metricName
        self.value = value
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(row: Row) throws {
        id = row["id"]
        pixel = row["pixel"]
        metricType = row["metric_type"]
        metricName = row["metric_name"]
        value = row["value"]
        let createdAtString: String = row["created_at"]
        let updatedAtString: String = row["updated_at"]
        createdAt = iso8601Formatter.date(from: createdAtString) ?? Date()
        updatedAt = iso8601Formatter.date(from: updatedAtString) ?? Date()
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["pixel"] = pixel
        container["metric_type"] = metricType
        container["metric_name"] = metricName
        container["value"] = value
        container["created_at"] = iso8601Formatter.string(from: createdAt)
        container["updated_at"] = iso8601Formatter.string(from: updatedAt)
    }
}

struct MetricsOutboxEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "metrics_outbox"

    var id: Int64?
    let pixel: String
    let intervalStart: Date
    let intervalEnd: Date
    let parameters: String
    var attempts: Int
    var lastAttempt: Date?

    init(id: Int64? = nil, pixel: String, intervalStart: Date, intervalEnd: Date, parameters: String, attempts: Int, lastAttempt: Date?) {
        self.id = id
        self.pixel = pixel
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.parameters = parameters
        self.attempts = attempts
        self.lastAttempt = lastAttempt
    }

    init(row: Row) throws {
        id = row["id"]
        pixel = row["pixel"]
        let startString: String = row["interval_start"]
        let endString: String = row["interval_end"]
        intervalStart = iso8601Formatter.date(from: startString) ?? Date()
        intervalEnd = iso8601Formatter.date(from: endString) ?? Date()
        parameters = row["parameters"]
        attempts = row["attempts"]
        if let lastAttemptString: String = row["last_attempt"] {
            lastAttempt = iso8601Formatter.date(from: lastAttemptString)
        } else {
            lastAttempt = nil
        }
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["pixel"] = pixel
        container["interval_start"] = iso8601Formatter.string(from: intervalStart)
        container["interval_end"] = iso8601Formatter.string(from: intervalEnd)
        container["parameters"] = parameters
        container["attempts"] = attempts
        container["last_attempt"] = lastAttempt.map { iso8601Formatter.string(from: $0) }
    }
}
