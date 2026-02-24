//
//  MetricsAggregator+Mutation.swift
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

public extension MetricsAggregator {

    /// Increments a counter by the given amount (default 1).
    /// Creates the counter (and pixel config with default interval) if it doesn't exist.
    func increment(pixel: String, name: String, by amount: Double = 1) throws {
        try dbPool.write { db in
            try ensurePixelConfig(pixel: pixel, db: db)
            try db.execute(
                sql: """
                INSERT INTO aggregated_metrics (pixel, metric_type, metric_name, value, created_at, updated_at)
                VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                ON CONFLICT(pixel, metric_name) DO UPDATE SET
                    value = value + excluded.value,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                """,
                arguments: [pixel, MetricTypeName.counter, name, amount]
            )
        }
    }

    /// Sets a gauge to an absolute value, replacing the previous reading.
    /// Creates the gauge (and pixel config with default interval) if it doesn't exist.
    func set(pixel: String, name: String, value: Double) throws {
        try dbPool.write { db in
            try ensurePixelConfig(pixel: pixel, db: db)
            try db.execute(
                sql: """
                INSERT INTO aggregated_metrics (pixel, metric_type, metric_name, value, created_at, updated_at)
                VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                ON CONFLICT(pixel, metric_name) DO UPDATE SET
                    value = excluded.value,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                """,
                arguments: [pixel, MetricTypeName.gauge, name, value]
            )
        }
    }
}
