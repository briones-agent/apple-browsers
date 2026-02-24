//
//  MetricsAggregator+Housekeeping.swift
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

    /// Returns the current value of a metric without collecting it.
    func peek(pixel: String, name: String) throws -> Double? {
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT value FROM aggregated_metrics WHERE pixel = ? AND metric_name = ?",
                arguments: [pixel, name]
            )
            return row?["value"] as? Double
        }
    }

    /// Removes all stored metrics. Primarily for testing.
    func reset() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM metrics_outbox")
            try db.execute(sql: "DELETE FROM aggregated_metrics")
            try db.execute(sql: "DELETE FROM metric_buckets")
            try db.execute(sql: "DELETE FROM pixel_config")
        }
    }
}
