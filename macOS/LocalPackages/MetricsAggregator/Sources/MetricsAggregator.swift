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
import Common
import MetricsAggregatorRust

/// Errors thrown by MetricsAggregator (Rust backend).
public enum MetricsAggregatorError: Error {
    case openFailed(message: String?)
    case operationFailed(message: String?)
}

/// SQLite-backed aggregator for counter and gauge metrics, with optional bucketing
/// and outbox-based collection for pixel emission.
/// Implementation is delegated to the Rust MetricsAggregatorRust library.
public final class MetricsAggregator {

    private var handle: UnsafeMutableRawPointer?

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
        let path = url.path
        let handlePtr: UnsafeMutableRawPointer? = path.withCString { pathCStr in
            let len = path.utf8.count
            return ddg_ma_open(pathCStr, len)
        }
        guard let h = handlePtr else {
            throw MetricsAggregatorError.openFailed(message: "Failed to open database")
        }
        handle = h
    }

    deinit {
        if let h = handle {
            ddg_ma_close(h)
            handle = nil
        }
    }

    private static func lastErrorMessage(from h: UnsafeMutableRawPointer??) -> String? {
        guard let handle = h ?? nil else { return nil }
        guard let ptr = ddg_ma_last_error_message(handle) else { return nil }
        defer { ddg_ma_free_string(ptr) }
        return String(cString: ptr)
    }

    private func withHandle<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        guard let h = handle else { throw MetricsAggregatorError.operationFailed(message: "handle closed") }
        return try body(h)
    }

    private func check(_ result: Int32) throws {
        if result == -1 {
            let msg = Self.lastErrorMessage(from: handle)
            throw MetricsAggregatorError.operationFailed(message: msg)
        }
    }
}

// MARK: - Registration
public extension MetricsAggregator {
    /// Registers an aggregation with the given name, interval, and full metric specs (counters/gauges with optional buckets).
    /// Creation date is stored for pruning relative to the latest aggregation.
    func registerAggregation(name: String, aggregationInterval: TimeInterval, metricsSpecs: [MetricSpec]) throws {
        let createdAt = MetricsAggregator.iso8601Now()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let specsData = try encoder.encode(metricsSpecs)
        let specsJson = String(data: specsData, encoding: .utf8) ?? "[]"
        try withHandle { h in
            try name.withCString { namePtr in
                try createdAt.withCString { createdPtr in
                    try specsJson.withCString { specsPtr in
                        try check(ddg_ma_register_aggregation(
                            h,
                            namePtr, name.utf8.count,
                            aggregationInterval,
                            createdPtr, createdAt.utf8.count,
                            specsPtr, specsJson.utf8.count
                        ))
                    }
                }
            }
        }
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}

// MARK: - Mutation
public extension MetricsAggregator {
    func increment(aggregationName: String, metricName: String, by amount: Double = 1) throws {
        try withHandle { h in
            try aggregationName.withCString { pixelPtr in
                try metricName.withCString { namePtr in
                    try check(ddg_ma_increment(h, pixelPtr, aggregationName.utf8.count, namePtr, metricName.utf8.count, amount))
                }
            }
        }
    }

    func set(aggregationName: String, metricName: String, value: Double) throws {
        try withHandle { h in
            try aggregationName.withCString { pixelPtr in
                try metricName.withCString { namePtr in
                    try check(ddg_ma_set(h, pixelPtr, aggregationName.utf8.count, namePtr, metricName.utf8.count, value))
                }
            }
        }
    }
}

// MARK: - Collection
public extension MetricsAggregator {
    @discardableResult
    func collectMetrics() throws -> Int {
        try withHandle { h in
            let n = ddg_ma_collect_metrics(h)
            if n == -1 {
                let msg = Self.lastErrorMessage(from: handle)
                throw MetricsAggregatorError.operationFailed(message: msg)
            }
            return Int(n)
        }
    }
}

// MARK: - Outbox
public extension MetricsAggregator {
    func pendingPixels(limit: Int = 50) throws -> [CollectedPixel] {
        try withHandle { h in
            guard let ptr = ddg_ma_pending_pixels(h, Int32(limit)) else {
                let msg = Self.lastErrorMessage(from: handle)
                throw MetricsAggregatorError.operationFailed(message: msg)
            }
            defer { ddg_ma_free_string(ptr) }
            let json = String(cString: ptr)
            let data = Data(json.utf8)
            let decoder = JSONDecoder()
            let entries = try decoder.decode([PendingPixelEntry].self, from: data)
            return entries.compactMap { e in
                guard let start = pendingPixelDateFormatter.date(from: e.interval_start),
                      let end = pendingPixelDateFormatter.date(from: e.interval_end) else { return nil }
                return CollectedPixel(id: e.id, start: start, end: end, pixel: e.pixel, parameters: e.parameters)
            }
        }
    }

    func markSent(id: Int64) throws {
        try withHandle { try check(ddg_ma_mark_sent($0, id)) }
    }

    func markFailed(id: Int64) throws {
        try withHandle { try check(ddg_ma_mark_failed($0, id)) }
    }

    @discardableResult
    func purgeExpired(maxAttempts: Int = 5) throws -> Int {
        try withHandle { h in
            let n = ddg_ma_purge_expired(h, Int32(maxAttempts))
            if n == -1 {
                let msg = Self.lastErrorMessage(from: handle)
                throw MetricsAggregatorError.operationFailed(message: msg)
            }
            return Int(n)
        }
    }

    /// Prunes aggregations whose created_at is older than (latest created_at - olderThanInterval).
    /// Use to remove old specs after a device restores an old session.
    @discardableResult
    func pruneAggregations(olderThanInterval: TimeInterval) throws -> Int {
        try withHandle { h in
            let n = ddg_ma_prune_aggregations(h, olderThanInterval)
            if n == -1 {
                let msg = Self.lastErrorMessage(from: handle)
                throw MetricsAggregatorError.operationFailed(message: msg)
            }
            return Int(n)
        }
    }
}

private struct PendingPixelEntry: Decodable {
    let id: Int64
    let interval_start: String
    let interval_end: String
    let pixel: String
    let parameters: String
}

private let pendingPixelDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

// MARK: - Housekeeping
public extension MetricsAggregator {
    func peek(aggregationName: String, metricName: String) throws -> Double? {
        try withHandle { h in
            var value: Double = 0
            let result: Int32 = try aggregationName.withCString { pixelPtr in
                try metricName.withCString { namePtr in
                    ddg_ma_peek(h, pixelPtr, aggregationName.utf8.count, namePtr, metricName.utf8.count, &value)
                }
            }
            if result == -1 {
                let msg = Self.lastErrorMessage(from: handle)
                throw MetricsAggregatorError.operationFailed(message: msg)
            }
            return result == 1 ? value : nil
        }
    }

    func reset() throws {
        try withHandle { try check(ddg_ma_reset($0)) }
    }
}
