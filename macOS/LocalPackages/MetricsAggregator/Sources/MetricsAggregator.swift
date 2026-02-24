//
//  MetricsAggregator.swift
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
import Common

/// Metric type constants for internal use.
enum MetricTypeName {
    static let counter = "counter"
    static let gauge = "gauge"
}

/// SQLite-backed aggregator for counter and gauge metrics, with optional bucketing
/// and outbox-based collection for pixel emission.
public final class MetricsAggregator {

    let dbPool: DatabasePool

    /// Initializes the aggregator, creating the database and schema if needed.
    /// - Parameter databaseURL: File URL for the SQLite database.
    ///   When nil, uses a standard app-support location under "MetricsAggregator".
    ///   For in-memory databases (e.g. tests), pass `URL(fileURLWithPath: ":memory:")`.
    public init(databaseURL: URL? = nil) throws {
        let url: URL
        if let databaseURL = databaseURL {
            url = databaseURL
        } else {
            let directory = FileManager.default.applicationSupportDirectoryForComponent(named: "MetricsAggregator")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("metrics_aggregator.db")
        }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbPool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        MetricsAggregatorSchema.registerMigrations(&migrator)
        try migrator.migrate(dbPool)
    }
}
