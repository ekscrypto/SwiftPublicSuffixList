//
//  PublicSuffixList.swift
//  SwiftPublicSuffixList
//
//  Created by Dave Poirier on 2022-01-30.
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license
//
//  References:
//  Algorithm based on Specifications from https://publicsuffix.org/list/
//  Length & allowed characters validation rules https://www.nic.ad.jp/timeline/en/20th/appendix1.html
//  Further checks added based on https://docs.microsoft.com/en-us/troubleshoot/windows-server/identity/naming-conventions-for-computer-domain-site-ou
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A thread-safe class for validating domain names against the Public Suffix List.
///
/// Internally backed by a memory-mapped binary trie (`registry.trie`). Load time
/// is effectively free and `isUnrestricted(_:)` runs in microseconds without
/// allocating heap memory proportional to the rule set.
public final class PublicSuffixList {

    public typealias URLRequestCompletion = (Data?, URLResponse?, Error?) -> Void
    public typealias URLRequestHandler = (URLRequest, @escaping URLRequestCompletion) -> Void
    public typealias Logger = (String) -> Void

    /// Logger used for diagnostic messages. Defaults to `print(_:)`.
    public static var logger: Logger = { print($0) }

    /// Default URL-request handler using `URLSession.shared`.
    public static let defaultUrlRequestHandler: URLRequestHandler = { request, completion in
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }

    /// Where the rules come from at construction time.
    public enum InitializerSource {

        /// Load trie bytes from the given path on disk. Falls back to the
        /// embedded rules if the file is missing or malformed.
        case filePath(String)

        /// Build an in-memory trie from the supplied rules.
        case rules([[String]])

        /// Fetch the latest PSL text from publicsuffix.org and build a trie
        /// from it. Falls back to embedded rules on failure.
        case onlineRegistry(URLRequest.CachePolicy?)

        /// Use the rules bundled with the package (`registry.trie`).
        case embedded
    }

    public typealias Match = PublicSuffixMatch

    // MARK: - Storage

    private var matcher: TrieMatcher
    private let urlRequestHandler: URLRequestHandler
    private let accessLock: NSLock
    private var updateThread: Thread?

    // MARK: - Initialization

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public static func list(
        from source: InitializerSource = .embedded,
        urlRequestHandler: @escaping URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler
    ) async -> PublicSuffixList {
        await withCheckedContinuation { continuation in
            continuation.resume(returning: PublicSuffixList(source: source,
                                                            urlRequestHandler: urlRequestHandler))
        }
    }

    public init(source: InitializerSource = .embedded,
                urlRequestHandler: @escaping URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler) {
        let initial: TrieMatcher
        switch source {
        case .rules(let customRules):
            let data = TrieBuilder.buildAndSerialize(rules: customRules)
            initial = TrieMatcher(data: data)

        case .onlineRegistry(let cachePolicy):
            precondition(!Thread.isMainThread,
                         "\(Self.self) May not be initialized on main thread due to long loading times")
            if let rules = PublicSuffixListOnlineRegistryFetcher.fetch(
                logger: Self.logger,
                cachePolicy: cachePolicy,
                urlRequestHandler: urlRequestHandler) {
                let data = TrieBuilder.buildAndSerialize(rules: rules)
                initial = TrieMatcher(data: data)
            } else {
                initial = Self.embeddedMatcher()
            }

        case .filePath(let path):
            precondition(!Thread.isMainThread,
                         "\(Self.self) May not be initialized on main thread due to long loading times")
            initial = Self.matcherFromFile(path: path) ?? Self.embeddedMatcher()

        case .embedded:
            initial = Self.embeddedMatcher()
        }
        self.matcher = initial
        self.accessLock = NSLock()
        self.urlRequestHandler = urlRequestHandler
    }

    // MARK: - Embedded resource loading

    /// Loads the package-embedded `registry.trie` with memory-mapped I/O.
    private static func embeddedMatcher() -> TrieMatcher {
        guard let url = Bundle.module.url(forResource: "registry", withExtension: "trie") else {
            preconditionFailure("registry.trie missing from SwiftPublicSuffixList bundle")
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return TrieMatcher(data: data)
        } catch {
            preconditionFailure("failed to load embedded registry.trie: \(error)")
        }
    }

    private static func matcherFromFile(path: String) -> TrieMatcher? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            Self.logger("\(Self.self) WARNING: unable to read file at \(path)")
            return nil
        }
        // Sanity-check the magic before handing to TrieMatcher (which precondition-fails).
        guard data.count >= 4,
              data[0] == 0x50, data[1] == 0x53, data[2] == 0x4C, data[3] == 0x54 else {
            Self.logger("\(Self.self) WARNING: file at \(path) is not a PSLT trie")
            return nil
        }
        return TrieMatcher(data: data)
    }

    // MARK: - Matching API

    /// Returns `true` when the candidate is a syntactically valid host and is
    /// not itself a public suffix.
    public func isUnrestricted(_ candidate: String) -> Bool {
        accessLock.lock()
        let m = matcher
        accessLock.unlock()
        return m.isUnrestricted(candidate)
    }

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public func isUnrestricted(_ candidate: String) async -> Bool {
        await withCheckedContinuation { continuation in
            continuation.resume(returning: self.isUnrestricted(candidate))
        }
    }

    public func match(_ candidate: String) -> Match? {
        accessLock.lock()
        let m = matcher
        accessLock.unlock()
        return m.match(candidate)
    }

    // MARK: - Static conveniences (custom rules or embedded)

    public static func isUnrestricted(_ candidate: String) -> Bool {
        embeddedMatcher().isUnrestricted(candidate)
    }

    public static func isUnrestricted(_ candidate: String, rules: [[String]]) -> Bool {
        let data = TrieBuilder.buildAndSerialize(rules: rules)
        return TrieMatcher(data: data).isUnrestricted(candidate)
    }

    public static func match(_ candidate: String) -> Match? {
        embeddedMatcher().match(candidate)
    }

    public static func match(_ candidate: String, rules: [[String]]) -> Match? {
        let data = TrieBuilder.buildAndSerialize(rules: rules)
        return TrieMatcher(data: data).match(candidate)
    }

    // MARK: - Online update

    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public func updateUsingOnlineRegistry(cachePolicy: URLRequest.CachePolicy? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            updateUsingOnlineRegistry(cachePolicy: cachePolicy) { updated in
                continuation.resume(returning: updated)
            }
        }
    }

    public func updateUsingOnlineRegistry(
        cachePolicy: URLRequest.CachePolicy? = nil,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard updateThread == nil else { return }
        let requestHandler = self.urlRequestHandler
        updateThread = Thread { [weak self] in
            var success = false
            if let rules = PublicSuffixListOnlineRegistryFetcher.fetch(
                logger: Self.logger,
                cachePolicy: cachePolicy,
                urlRequestHandler: requestHandler
            ) {
                let data = TrieBuilder.buildAndSerialize(rules: rules)
                let newMatcher = TrieMatcher(data: data)
                self?.accessLock.lock()
                self?.matcher = newMatcher
                self?.accessLock.unlock()
                Self.logger("\(Self.self) Public Suffix List updated")
                success = true
            }
            completion(success)
            self?.updateThread = nil
        }
        updateThread?.start()
    }

    // MARK: - Export

    /// Writes the current trie bytes to disk. The resulting file can be
    /// reloaded with `init(source: .filePath(path))`.
    public func export(
        to path: String,
        writeOptions: Data.WritingOptions = []
    ) throws {
        accessLock.lock()
        let bytes = matcher.data
        accessLock.unlock()
        try bytes.write(to: URL(fileURLWithPath: path), options: writeOptions)
    }
}
