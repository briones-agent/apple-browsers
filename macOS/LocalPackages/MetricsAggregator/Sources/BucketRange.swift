//
//  BucketRange.swift
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

/// Defines a single bucket range for bucketed metric output.
public struct BucketRange {
    public let minInclusive: Double
    public let maxExclusive: Double?
    public let name: String

    public init(minInclusive: Double, maxExclusive: Double? = nil, name: String) {
        self.minInclusive = minInclusive
        self.maxExclusive = maxExclusive
        self.name = name
    }
}
