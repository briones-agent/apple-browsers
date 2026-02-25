//
//  MetricSpec.swift
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

/// Metric kind: counter (summed on increment) or gauge (replaced on set).
public enum MetricType: String, Encodable {
    case counter
    case gauge
}

/// How the metric value is emitted when collecting: integer (default) or double.
public enum MetricValueType: String, Encodable {
    case int
    case double
}

/// Spec for a single metric within an aggregation.
public struct MetricSpec: Encodable {
    public let name: String
    public let type: MetricType
    public let buckets: [BucketRange]?
    public let valueType: MetricValueType

    public init(name: String, type: MetricType, buckets: [BucketRange]? = nil, valueType: MetricValueType = .int) {
        self.name = name
        self.type = type
        self.buckets = buckets
        self.valueType = valueType
    }
}
