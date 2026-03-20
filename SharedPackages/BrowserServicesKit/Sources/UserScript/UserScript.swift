//
//  UserScript.swift
//
//  Copyright © 2021 DuckDuckGo. All rights reserved.
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
import WebKit
import CryptoKit
private enum JSFileCache {

    private static let lock = NSLock()
    private static var storage = [String: String]()

    static func content(forFile file: String, in bundle: Bundle) throws -> String {
        let cacheKey = bundle.bundlePath + "/" + file

        lock.lock()
        let cached = storage[cacheKey]
        lock.unlock()

        if let cached { return cached }

        guard let path = bundle.path(forResource: file, ofType: "js") else {
            throw UserScriptError.failedToLoadJS(jsFile: file, error: CocoaError(.fileReadNoSuchFile))
        }

        do {
            let content = try String(contentsOfFile: path)
            lock.lock()
            storage[cacheKey] = content
            lock.unlock()
            return content
        } catch {
            throw UserScriptError.failedToLoadJS(jsFile: file, error: error)
        }
    }

    /// Single-pass replacement of `$TOKEN$`-style placeholders.
    /// Scans the template's UTF-8 bytes once, matching replacement keys
    /// at every `$` and copying non-matching regions in bulk.
    static func applyReplacements(_ template: String, _ replacements: [String: String]) -> String {
        guard !replacements.isEmpty else { return template }

        let templateUTF8 = Array(template.utf8)
        let dollar = UInt8(ascii: "$")
        let keys = replacements.map { (utf8: Array($0.key.utf8), value: Array($0.value.utf8)) }

        var result = [UInt8]()
        result.reserveCapacity(templateUTF8.count)

        var i = 0
        while i < templateUTF8.count {
            if templateUTF8[i] == dollar {
                var matched = false
                for entry in keys {
                    let end = i + entry.utf8.count
                    if end <= templateUTF8.count,
                       templateUTF8[i..<end].elementsEqual(entry.utf8) {
                        result.append(contentsOf: entry.value)
                        i = end
                        matched = true
                        break
                    }
                }
                if !matched {
                    result.append(templateUTF8[i])
                    i += 1
                }
            } else {
                let start = i
                while i < templateUTF8.count && templateUTF8[i] != dollar {
                    i += 1
                }
                result.append(contentsOf: templateUTF8[start..<i])
            }
        }

        return String(decoding: result, as: UTF8.self)
    }
}

public struct WKUserScriptBox: @unchecked Sendable {
    public let wkUserScript: WKUserScript
}
public protocol UserScript: WKScriptMessageHandler {

    var source: String { get }
    var injectionTime: WKUserScriptInjectionTime { get }
    var forMainFrameOnly: Bool { get }
    var requiresRunInPageContentWorld: Bool { get }

    var messageNames: [String] { get }

    func makeWKUserScript() async -> WKUserScriptBox

}

extension UserScript {

    static public var requiresRunInPageContentWorld: Bool {
        return false
    }

    public var requiresRunInPageContentWorld: Bool {
        return false
    }

    @available(macOS 11.0, iOS 14.0, *)
    @MainActor
    static func getContentWorld(_ requiresRunInPageContentWorld: Bool) -> WKContentWorld {
        if requiresRunInPageContentWorld {
            return .page
        }
        return .defaultClient
    }

    @available(macOS 11.0, iOS 14.0, *)
    @MainActor
    public func getContentWorld() -> WKContentWorld {
        return Self.getContentWorld(requiresRunInPageContentWorld)
    }

    public static func loadJS(_ jsFile: String, from bundle: Bundle, withReplacements replacements: [String: String] = [:]) throws -> String {
        let js = try JSFileCache.content(forFile: jsFile, in: bundle)
        return JSFileCache.applyReplacements(js, replacements)
    }

    fileprivate nonisolated static func prepareScriptSource(from source: String) -> String {
        let hash = SHA256.hash(data: Data(source.utf8)).hashValue

        // This prevents the script being executed twice which appears to be a WKWebKit issue for about:blank frames when the location changes
        return """
        (() => {
            if (window.navigator._duckduckgoloader_ && window.navigator._duckduckgoloader_.includes('\(hash)')) {return}
            \(source)
            window.navigator._duckduckgoloader_ = window.navigator._duckduckgoloader_ || [];
            window.navigator._duckduckgoloader_.push('\(hash)')
        })()
        """
    }

    @MainActor
    fileprivate static func makeWKUserScript(from source: String,
                                             injectionTime: WKUserScriptInjectionTime,
                                             forMainFrameOnly: Bool,
                                             requiresRunInPageContentWorld: Bool = false) -> WKUserScriptBox {
        if #available(macOS 11.0, iOS 14.0, *) {
            let contentWorld = getContentWorld(requiresRunInPageContentWorld)
            return .init(wkUserScript: WKUserScript(source: source,
                                                    injectionTime: injectionTime,
                                                    forMainFrameOnly: forMainFrameOnly,
                                                    in: contentWorld))
        } else {
            return .init(wkUserScript: WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly))
        }
    }

    public func makeWKUserScript() async -> WKUserScriptBox {
        let source = await Task.detached { [source] in Self.prepareScriptSource(from: source) }.result.get()
        return await Self.makeWKUserScript(from: source,
                                           injectionTime: injectionTime,
                                           forMainFrameOnly: forMainFrameOnly,
                                           requiresRunInPageContentWorld: requiresRunInPageContentWorld)
    }

    @MainActor
    public func makeWKUserScriptSync() -> WKUserScript {
        return Self.makeWKUserScript(from: Self.prepareScriptSource(from: source),
                                     injectionTime: injectionTime,
                                     forMainFrameOnly: forMainFrameOnly,
                                     requiresRunInPageContentWorld: requiresRunInPageContentWorld).wkUserScript
    }

}

extension StaticUserScript {

    @MainActor
    public static func makeWKUserScript() -> WKUserScript {
        return makeWKUserScript(from: prepareScriptSource(from: source),
                                injectionTime: injectionTime,
                                forMainFrameOnly: forMainFrameOnly).wkUserScript
    }

}

public enum UserScriptError: Error {
    case failedToLoadJS(jsFile: String, error: Error)
}
