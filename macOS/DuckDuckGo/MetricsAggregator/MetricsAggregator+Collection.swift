//
//  MetricsAggregator+Collection.swift
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

public extension MetricsAggregator {

    /// Collects all metrics whose pixel's aggregation interval has elapsed since the metric was last updated,
    /// moves them into the outbox table, and removes them from the live aggregation table.
    /// - Returns: The count of outbox entries (pixels) created.
    @discardableResult
    func collectMetrics() throws -> Int {
        try dbPool.write { db in
            let matureMetrics = try fetchMatureMetrics(db: db)
            let idsToDelete = matureMetrics.map { $0.id! }
            guard !matureMetrics.isEmpty else { return 0 }

            let bucketsByKey = try fetchBucketsByPixelAndMetric(db: db)
            var byPixel: [String: [(metric: AggregatedMetric, resolvedValue: String)]] = [:]
            for metric in matureMetrics {
                let key = "\(metric.pixel)|\(metric.metricName)"
                let buckets = bucketsByKey[key] ?? []
                if let resolved = resolveValue(metric.value, buckets: buckets) {
                    byPixel[metric.pixel, default: []].append((metric, resolved))
                }
            }

            let intervalEnd = Date()
            var outboxCount = 0
            for (pixel, items) in byPixel where !items.isEmpty {
                let intervalStart = items.map { $0.metric.createdAt }.min() ?? intervalEnd
                let parameters = urlEncodedParameters(from: items.map { ($0.metric.metricType, $0.metric.metricName, $0.resolvedValue) })
                var outboxEntry = MetricsOutboxEntry(
                    id: nil,
                    pixel: pixel,
                    intervalStart: intervalStart,
                    intervalEnd: intervalEnd,
                    parameters: parameters,
                    attempts: 0,
                    lastAttempt: nil
                )
                try outboxEntry.insert(db)
                outboxCount += 1
            }

            for id in idsToDelete {
                try db.execute(sql: "DELETE FROM aggregated_metrics WHERE id = ?", arguments: [id])
            }
            return outboxCount
        }
    }
}

extension MetricsAggregator {

    func fetchMatureMetrics(db: Database) throws -> [AggregatedMetric] {
        let sql = """
        SELECT m.id, m.pixel, m.metric_type, m.metric_name, m.value, m.created_at, m.updated_at
        FROM aggregated_metrics m
        JOIN pixel_config c ON m.pixel = c.pixel
        WHERE m.updated_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-' || CAST(c.aggregation_interval AS TEXT) || ' seconds')
        """
        return try AggregatedMetric.fetchAll(db, sql: sql)
    }

    func fetchBucketsByPixelAndMetric(db: Database) throws -> [String: [MetricBucket]] {
        let buckets = try MetricBucket.order(Column("ordinal")).fetchAll(db)
        var result: [String: [MetricBucket]] = [:]
        for b in buckets {
            let key = "\(b.pixel)|\(b.metricName)"
            result[key, default: []].append(b)
        }
        return result
    }

    func resolveValue(_ value: Double, buckets: [MetricBucket]) -> String? {
        if buckets.isEmpty {
            return "\(value)"
        }
        for bucket in buckets.sorted(by: { $0.ordinal < $1.ordinal }) {
            if value >= bucket.minInclusive {
                if bucket.maxExclusive == nil || value < bucket.maxExclusive! {
                    return bucket.name
                }
            }
        }
        return nil
    }

    func urlEncodedParameters(from items: [(metricType: String, metricName: String, value: String)]) -> String {
        let queryItems = items.map { item in
            URLQueryItem(name: "\(item.metricType)_\(item.metricName)", value: item.value)
        }
        var components = URLComponents()
        components.queryItems = queryItems
        return components.percentEncodedQuery ?? ""
    }
}
