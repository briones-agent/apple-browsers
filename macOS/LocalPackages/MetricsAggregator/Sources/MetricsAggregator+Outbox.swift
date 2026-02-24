//
//  MetricsAggregator+Outbox.swift
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

    /// Returns outbox entries that are ready for sending.
    /// Each entry is (start, end, pixel, parameters) where parameters are URL-encoded key-value pairs.
    /// Entries are ordered oldest-first and limited to `limit`.
    func pendingPixels(limit: Int = 50) throws -> [CollectedPixel] {
        try dbPool.read { db in
            let entries = try MetricsOutboxEntry.order(Column("id")).limit(limit).fetchAll(db)
            return entries.compactMap { entry in
                guard let id = entry.id else { return nil }
                return CollectedPixel(
                    id: id,
                    start: entry.intervalStart,
                    end: entry.intervalEnd,
                    pixel: entry.pixel,
                    parameters: entry.parameters
                )
            }
        }
    }

    /// Marks an outbox entry as successfully sent, removing it and its associated metric items from the outbox.
    func markSent(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM metrics_outbox WHERE id = ?", arguments: [id])
        }
    }

    /// Records a failed send attempt, incrementing the retry counter.
    func markFailed(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE metrics_outbox SET attempts = attempts + 1, last_attempt = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                WHERE id = ?
                """,
                arguments: [id]
            )
        }
    }

    /// Removes outbox entries that have exceeded the maximum retry count.
    /// - Returns: The number of purged entries.
    @discardableResult
    func purgeExpired(maxAttempts: Int = 5) throws -> Int {
        try dbPool.write { db in
            let deleted = try MetricsOutboxEntry.filter(Column("attempts") > maxAttempts).deleteAll(db)
            return deleted
        }
    }
}
