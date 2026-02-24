//
//  MetricsAggregator+Registration.swift
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

private let defaultAggregationInterval: TimeInterval = 3600

public extension MetricsAggregator {

    /// Registers a pixel with its aggregation interval.
    /// If the pixel is already registered, updates its interval.
    func registerPixel(_ pixel: String, aggregationInterval: TimeInterval = 3600) throws {
        try dbPool.write { db in
            try PixelConfig(pixel: pixel, aggregationInterval: aggregationInterval).save(db, onConflict: Database.ConflictResolution.replace)
        }
    }

    /// Registers a counter metric under a pixel.
    /// No-op if the metric already exists.
    /// If the pixel has not been registered, it is auto-registered with the default aggregation interval.
    func registerCounter(pixel: String, name: String, buckets: [BucketRange]? = nil) throws {
        try dbPool.write { db in
            try ensurePixelConfig(pixel: pixel, db: db)
            try replaceBuckets(pixel: pixel, metricName: name, buckets: buckets, db: db)
        }
    }

    /// Registers a gauge metric under a pixel.
    /// No-op if the metric already exists.
    /// If the pixel has not been registered, it is auto-registered with the default aggregation interval.
    func registerGauge(pixel: String, name: String, buckets: [BucketRange]? = nil) throws {
        try dbPool.write { db in
            try ensurePixelConfig(pixel: pixel, db: db)
            try replaceBuckets(pixel: pixel, metricName: name, buckets: buckets, db: db)
        }
    }
}

extension MetricsAggregator {

    func ensurePixelConfig(pixel: String, db: Database) throws {
        try PixelConfig(pixel: pixel, aggregationInterval: defaultAggregationInterval).save(db, onConflict: Database.ConflictResolution.ignore)
    }

    func replaceBuckets(pixel: String, metricName: String, buckets: [BucketRange]?, db: Database) throws {
        try db.execute(sql: "DELETE FROM metric_buckets WHERE pixel = ? AND metric_name = ?", arguments: [pixel, metricName])
        guard let buckets = buckets else { return }
        for (ordinal, bucket) in buckets.enumerated() {
            var record = MetricBucket(
                id: nil,
                pixel: pixel,
                metricName: metricName,
                ordinal: ordinal,
                minInclusive: bucket.minInclusive,
                maxExclusive: bucket.maxExclusive,
                name: bucket.name
            )
            try record.insert(db)
        }
    }
}
