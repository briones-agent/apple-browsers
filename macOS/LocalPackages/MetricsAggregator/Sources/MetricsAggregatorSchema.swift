//
//  MetricsAggregatorSchema.swift
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

enum MetricsAggregatorSchema {

    static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")

            try db.create(table: "pixel_config") { t in
                t.primaryKey("pixel", .text)
                t.column("aggregation_interval", .double).notNull().defaults(to: 3600)
            }

            try db.create(table: "metric_buckets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pixel", .text).notNull()
                t.column("metric_name", .text).notNull()
                t.column("ordinal", .integer).notNull()
                t.column("min_inclusive", .double).notNull()
                t.column("max_exclusive", .double)
                t.column("name", .text).notNull()
            }
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_metric_buckets_unique ON metric_buckets(pixel, metric_name, ordinal)")

            try db.execute(sql: """
                CREATE TABLE aggregated_metrics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pixel TEXT NOT NULL,
                    metric_type TEXT NOT NULL,
                    metric_name TEXT NOT NULL,
                    value REAL NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_aggregated_metrics_unique ON aggregated_metrics(pixel, metric_name)")

            try db.execute(sql: """
                CREATE TABLE metrics_outbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pixel TEXT NOT NULL,
                    interval_start TEXT NOT NULL,
                    interval_end TEXT NOT NULL,
                    parameters TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_attempt TEXT
                )
                """)
        }
    }
}
