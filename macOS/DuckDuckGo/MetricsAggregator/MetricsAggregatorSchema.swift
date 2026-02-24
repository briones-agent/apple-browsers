//
//  MetricsAggregatorSchema.swift
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
                t.uniqueKey(["pixel", "metric_name", "ordinal"])
            }

            let timestampDefault = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
            try db.create(table: "aggregated_metrics") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pixel", .text).notNull()
                t.column("metric_type", .text).notNull()
                t.column("metric_name", .text).notNull()
                t.column("value", .double).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull().defaults(sql: timestampDefault)
                t.column("updated_at", .text).notNull().defaults(sql: timestampDefault)
                t.uniqueKey(["pixel", "metric_name"])
            }

            try db.create(table: "metrics_outbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pixel", .text).notNull()
                t.column("interval_start", .text).notNull()
                t.column("interval_end", .text).notNull()
                t.column("parameters", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_attempt", .text)
            }
        }
    }
}
