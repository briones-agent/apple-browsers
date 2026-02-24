//
//  MetricsAggregator+Collection.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this code except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//

import Foundation
import GRDB

private let collectMetricsSQL = """
WITH mature AS (
  SELECT m.id, m.pixel, m.metric_type, m.metric_name, m.value, m.created_at
  FROM aggregated_metrics m
  JOIN pixel_config c ON m.pixel = c.pixel
  WHERE m.created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-' || CAST(c.aggregation_interval AS TEXT) || ' seconds')
),
with_bucket AS (
  SELECT mature.*,
    (SELECT b.name FROM metric_buckets b
     WHERE b.pixel = mature.pixel AND b.metric_name = mature.metric_name
       AND mature.value >= b.min_inclusive
       AND (b.max_exclusive IS NULL OR mature.value < b.max_exclusive)
     ORDER BY b.ordinal LIMIT 1) AS bucket_name,
    EXISTS (SELECT 1 FROM metric_buckets b2 WHERE b2.pixel = mature.pixel AND b2.metric_name = mature.metric_name) AS has_buckets
  FROM mature
),
with_resolved AS (
  SELECT id, pixel, metric_type, metric_name, created_at,
    CASE
      WHEN bucket_name IS NOT NULL THEN bucket_name
      WHEN has_buckets THEN NULL
      ELSE CAST(value AS TEXT)
    END AS resolved_value
  FROM with_bucket
)
SELECT id, pixel, metric_type, metric_name, created_at, resolved_value
FROM with_resolved
WHERE resolved_value IS NOT NULL
"""

public extension MetricsAggregator {

    /// Collects all metrics whose pixel's aggregation interval has elapsed since the metric was first created,
    /// moves them into the outbox table, and removes them from the live aggregation table.
    /// - Returns: The count of outbox entries (pixels) created.
    @discardableResult
    func collectMetrics() throws -> Int {
        try dbPool.write { db in
            let rows = try Row.fetchAll(db, sql: collectMetricsSQL)
            guard !rows.isEmpty else { return 0 }

            let intervalEnd = iso8601Now()
            var byPixel: [String: (minCreatedAt: String, items: [(metricType: String, metricName: String, value: String)])] = [:]
            var idsToDelete: [Int64] = []
            for row in rows {
                let id: Int64 = row["id"]
                idsToDelete.append(id)
                let pixel: String = row["pixel"]
                let metricType: String = row["metric_type"]
                let metricName: String = row["metric_name"]
                let createdAt: String = row["created_at"]
                let value: String = row["resolved_value"]
                if byPixel[pixel] == nil {
                    byPixel[pixel] = (minCreatedAt: createdAt, items: [])
                }
                var entry = byPixel[pixel]!
                if createdAt < entry.minCreatedAt {
                    entry.minCreatedAt = createdAt
                }
                entry.items.append((metricType, metricName, value))
                byPixel[pixel] = entry
            }

            var outboxCount = 0
            for (pixel, entry) in byPixel where !entry.items.isEmpty {
                let parameters = urlEncodedParameters(from: entry.items)
                try db.execute(
                    sql: """
                    INSERT INTO metrics_outbox (pixel, interval_start, interval_end, parameters, attempts, last_attempt)
                    VALUES (?, ?, ?, ?, 0, NULL)
                    """,
                    arguments: [pixel, entry.minCreatedAt, intervalEnd, parameters]
                )
                outboxCount += 1
            }

            if !idsToDelete.isEmpty {
                let placeholders = idsToDelete.map { _ in "?" }.joined(separator: ", ")
                try db.execute(sql: "DELETE FROM aggregated_metrics WHERE id IN (\(placeholders))", arguments: StatementArguments(idsToDelete))
            }
            return outboxCount
        }
    }
}

private func iso8601Now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
}

private func urlEncodedParameters(from items: [(metricType: String, metricName: String, value: String)]) -> String {
    let queryItems = items.map { item in
        URLQueryItem(name: "\(item.metricType)_\(item.metricName)", value: item.value)
    }
    var components = URLComponents()
    components.queryItems = queryItems
    return components.percentEncodedQuery ?? ""
}
