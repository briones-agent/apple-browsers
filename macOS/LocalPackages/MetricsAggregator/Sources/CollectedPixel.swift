//
//  CollectedPixel.swift
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

/// A collected pixel payload ready for dispatch.
/// - start: Timestamp when the collection interval was opened.
/// - end: Timestamp when collection was done.
/// - pixel: Pixel name.
/// - parameters: URL-encoded key-value pairs from the metrics (e.g. "counter_foo=1&gauge_bar=bucket_a").
public struct CollectedPixel {
    public let id: Int64
    public let start: Date
    public let end: Date
    public let pixel: String
    public let parameters: String

    public init(id: Int64, start: Date, end: Date, pixel: String, parameters: String) {
        self.id = id
        self.start = start
        self.end = end
        self.pixel = pixel
        self.parameters = parameters
    }
}
