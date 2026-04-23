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
/// `PublicSuffixList` determines whether a domain is "restricted" (a public
/// suffix like `com` or `co.uk`) or "unrestricted" (a registrable domain like
/// `yahoo.com`).
///
/// ## Overview
///
/// Internally backed by a memory-mapped binary trie (`registry.trie`). Loading
/// the library does not parse any text format or allocate per-rule heap
/// memory — the embedded resource is `mmap`'d and walked in place. The
/// zero-allocation ``isUnrestricted(_:)-6qd5f`` fast path runs in microseconds
/// regardless of rule-set size.
///
/// ## Quick start
///
/// ```swift
/// // Static shortcut — uses the embedded rules.
/// if PublicSuffixList.isUnrestricted("yahoo.com") {
///     // yahoo.com is a registrable domain
/// }
///
/// // Instance with the embedded rules (use when you need runtime updates).
/// let list = PublicSuffixList()
/// if list.isUnrestricted("bbc.co.uk") {
///     // bbc.co.uk is registrable
/// }
///
/// // Async variant.
/// let list = await PublicSuffixList.list()
/// if await list.isUnrestricted("example.com") { ... }
/// ```
///
/// ## Hostname input format (v3.0+)
///
/// Hostnames passed to ``isUnrestricted(_:)-6qd5f`` and ``match(_:)-6q0fd``
/// must be ASCII. IDN labels must be Punycode-encoded (ACE form) by the
/// caller:
///
/// ```swift
/// // ❌ rejected — raw Unicode fails syntax validation
/// list.isUnrestricted("example.香港")
///
/// // ✅ correct
/// list.isUnrestricted("example.xn--j6w193g")
/// ```
///
/// Rule inputs to ``InitializerSource/rules(_:)`` may still be in UTF-8
/// form — the builder runs each label through an RFC 3492 Punycode encoder
/// at build time.
///
/// ## Thread safety
///
/// All public methods are thread-safe. The trie can be replaced at runtime
/// via ``updateUsingOnlineRegistry(cachePolicy:completion:)`` without
/// interrupting in-flight match calls.
///
/// ## Topics
///
/// ### Creating a Public Suffix List
/// - ``init(source:urlRequestHandler:)``
/// - ``list(from:urlRequestHandler:)``
///
/// ### Validating Domains
/// - ``isUnrestricted(_:)-6qd5f``
/// - ``isUnrestricted(_:)-7n6op``
/// - ``isUnrestricted(_:rules:)``
/// - ``match(_:)-6q0fd``
/// - ``match(_:rules:)``
///
/// ### Encoding Hostnames
/// - ``ace(_:)``
///
/// ### Updating Rules
/// - ``updateUsingOnlineRegistry(cachePolicy:)-6bqvv``
/// - ``updateUsingOnlineRegistry(cachePolicy:completion:)``
/// - ``export(to:writeOptions:)``
public final class PublicSuffixList {

    /// Completion handler type for URL request operations.
    public typealias URLRequestCompletion = (Data?, URLResponse?, Error?) -> Void

    /// Handler type for performing URL requests. Exposed so tests and custom
    /// networking stacks can intercept traffic to `publicsuffix.org`.
    public typealias URLRequestHandler = (URLRequest, @escaping URLRequestCompletion) -> Void

    /// Logger function type for diagnostic messages.
    public typealias Logger = (String) -> Void

    /// Logger used for diagnostic messages. Defaults to `print(_:)`. Replace
    /// with your own function to route warnings into an app logger.
    public static var logger: Logger = { print($0) }

    /// Default URL-request handler using `URLSession.shared`. Override by
    /// passing a custom handler to ``init(source:urlRequestHandler:)`` when
    /// you need to integrate with a specific networking stack.
    public static let defaultUrlRequestHandler: URLRequestHandler = { request, completion in
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }

    /// The data source used to initialize the Public Suffix List rules.
    ///
    /// ```swift
    /// // Use the embedded binary trie
    /// let list = PublicSuffixList(source: .embedded)
    ///
    /// // Supply custom rules — a trie is built in memory
    /// let custom = PublicSuffixList(source: .rules([["com"], ["co", "uk"]]))
    ///
    /// // Load a previously exported trie from disk
    /// let cached = PublicSuffixList(source: .filePath("/path/to/registry.trie"))
    ///
    /// // Fetch the latest list from publicsuffix.org (blocks — background thread only)
    /// let fresh = PublicSuffixList(source: .onlineRegistry(nil))
    /// ```
    public enum InitializerSource {

        /// Load trie bytes from the given path on disk. The file must be in
        /// the binary trie format produced by ``export(to:writeOptions:)``;
        /// other formats fall back to the embedded rules with a warning.
        case filePath(String)

        /// Build an in-memory trie from the supplied `[[String]]` rules. Each
        /// inner array is a rule in leftmost-first order; `*` and `!` carry
        /// the usual PSL semantics.
        ///
        /// Labels may be supplied in UTF-8 form (matching the PSL .dat text
        /// format) — the builder runs each one through Punycode so the
        /// serialized trie stores only ACE-form ASCII bytes. Pure-ASCII
        /// labels pass through verbatim.
        case rules([[String]])

        /// Fetch the latest PSL text from publicsuffix.org and build a trie
        /// from it. Falls back to the embedded rules on failure. Blocks the
        /// calling thread; must not be invoked on the main thread.
        case onlineRegistry(URLRequest.CachePolicy?)

        /// Use the rules bundled with the package (`registry.trie`).
        case embedded
    }

    /// Result returned by ``match(_:)-6q0fd``.
    ///
    /// ```swift
    /// public struct Match {
    ///     public let prevailingRule: [String]
    ///     public let isRestricted: Bool
    /// }
    /// ```
    ///
    /// - `prevailingRule` is the rule that produced the match, in the same
    ///   leftmost-first order used when supplying rules. Exception rules
    ///   include the leading `!` on their leftmost label.
    /// - `isRestricted` is `true` when the candidate itself is a public
    ///   suffix and therefore should not be treated as a registrable domain.
    public typealias Match = PublicSuffixMatch

    // MARK: - Storage

    private var matcher: TrieMatcher
    private let urlRequestHandler: URLRequestHandler
    private let accessLock: NSLock
    private var updateThread: Thread?

    // MARK: - Initialization

    /// Asynchronously creates a new `PublicSuffixList` from the specified source.
    ///
    /// Preferred over ``init(source:urlRequestHandler:)`` when using
    /// async/await, because the potentially blocking sources (`onlineRegistry`,
    /// `filePath`) require a non-main thread.
    ///
    /// ```swift
    /// let list = await PublicSuffixList.list(from: .onlineRegistry(nil))
    /// if await list.isUnrestricted("example.com") {
    ///     // …
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - source: The data source for loading rules. Defaults to ``InitializerSource/embedded``.
    ///   - urlRequestHandler: Handler for HTTP requests to `publicsuffix.org`.
    /// - Returns: A configured `PublicSuffixList` instance.
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

    /// Creates a new `PublicSuffixList` using the specified source.
    ///
    /// - Important: The `.onlineRegistry` and `.filePath` sources may block
    ///   briefly and are not permitted on the main thread (the initializer
    ///   will crash with a precondition failure). `.embedded` and `.rules`
    ///   are safe from any thread.
    ///
    /// - Parameters:
    ///   - source: The data source for loading rules. Defaults to ``InitializerSource/embedded``.
    ///   - urlRequestHandler: Handler used by runtime registry updates.
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
        // Full structural + CRC validation before we trust the buffer. Any
        // failure falls back to the embedded rules via the caller.
        let logger = Self.logger
        return TrieMatcher.loadValidated(data: data) { reason in
            logger("\(Self.self) WARNING: rejecting file at \(path) — \(reason)")
        }
    }

    // MARK: - Matching API

    /// Returns `true` when the candidate is a syntactically valid host and
    /// is *not* itself a public suffix.
    ///
    /// This is the zero-allocation fast path — use it when you only need a
    /// yes/no answer.
    ///
    /// - Important: The candidate must be in ASCII / ACE (Punycode) form.
    ///   IDN hostnames like `"example.香港"` are rejected as invalid — encode
    ///   each label first, e.g. `"example.xn--j6w193g"`. This matches the
    ///   DNS wire format and RFC 5321 hostname syntax.
    ///
    /// - Parameter candidate: The domain string to validate. Must be ASCII.
    /// - Returns: `true` when the domain is valid and registrable; `false`
    ///   when it's a public suffix, fails RFC5321 syntax checks, contains
    ///   non-ASCII bytes, or does not match any rule.
    public func isUnrestricted(_ candidate: String) -> Bool {
        accessLock.lock()
        let m = matcher
        accessLock.unlock()
        return m.isUnrestricted(candidate)
    }

    /// Asynchronous variant of ``isUnrestricted(_:)-6qd5f``.
    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public func isUnrestricted(_ candidate: String) async -> Bool {
        await withCheckedContinuation { continuation in
            continuation.resume(returning: self.isUnrestricted(candidate))
        }
    }

    /// Matches the candidate against the rules and returns a ``Match`` with
    /// the prevailing rule and restriction flag, or `nil` when the candidate
    /// is syntactically invalid or does not match any rule.
    ///
    /// - Important: The candidate must be in ASCII / ACE (Punycode) form;
    ///   see the type-level documentation on hostname input format. Raw
    ///   Unicode inputs return `nil`.
    public func match(_ candidate: String) -> Match? {
        accessLock.lock()
        let m = matcher
        accessLock.unlock()
        return m.match(candidate)
    }

    // MARK: - Static conveniences

    /// Checks `candidate` against the package-embedded Public Suffix List.
    ///
    /// Convenience for the common case where you don't need a long-lived
    /// `PublicSuffixList` instance.
    public static func isUnrestricted(_ candidate: String) -> Bool {
        embeddedMatcher().isUnrestricted(candidate)
    }

    /// Checks `candidate` against a custom rule set.
    ///
    /// Builds a trie from the supplied rules on every call, so prefer the
    /// instance API (`PublicSuffixList(source: .rules(myRules))`) when
    /// reusing the same rule set across many checks.
    public static func isUnrestricted(_ candidate: String, rules: [[String]]) -> Bool {
        let data = TrieBuilder.buildAndSerialize(rules: rules)
        return TrieMatcher(data: data).isUnrestricted(candidate)
    }

    /// Full-match variant using the embedded rules. See ``match(_:)-6q0fd``.
    public static func match(_ candidate: String) -> Match? {
        embeddedMatcher().match(candidate)
    }

    /// Full-match variant against a custom rule set. Builds a trie on every
    /// call — prefer the instance API for repeated use.
    public static func match(_ candidate: String, rules: [[String]]) -> Match? {
        let data = TrieBuilder.buildAndSerialize(rules: rules)
        return TrieMatcher(data: data).match(candidate)
    }

    // MARK: - ACE encoding

    /// Returns the ACE (Punycode) form of a full hostname.
    ///
    /// Splits on `.`, runs each label through an RFC 3492 Punycode encoder,
    /// and rejoins with `.`. Pure-ASCII labels pass through verbatim; labels
    /// containing any non-ASCII scalar are emitted in `xn--…` form.
    ///
    /// Use this to prepare IDN hostnames for ``isUnrestricted(_:)-6qd5f``
    /// and ``match(_:)-6q0fd``, which accept ASCII hostnames only:
    ///
    /// ```swift
    /// let host = PublicSuffixList.ace("example.香港") // "example.xn--j6w193g"
    /// PublicSuffixList.isUnrestricted(host)           // true
    /// ```
    ///
    /// This is a pure string transformation — no syntax validation, no case
    /// folding, and no Unicode normalization. Feed already-canonicalized
    /// labels (NFC, lowercased as appropriate) if you need those; see the
    /// `IDNA` / Unicode spec for full IDN processing beyond the encoding
    /// step.
    ///
    /// The library intentionally does not expose a decoder — hostnames only
    /// need to reach ACE form to match against the trie.
    public static func ace(_ hostname: String) -> String {
        hostname.components(separatedBy: ".")
            .map(Punycode.toACE)
            .joined(separator: ".")
    }

    // MARK: - Online update

    /// Asynchronously replaces the in-memory rules with those fetched from
    /// publicsuffix.org. Returns `true` on success; on failure the previous
    /// rules remain active.
    ///
    /// ```swift
    /// let list = await PublicSuffixList.list()
    /// if await list.updateUsingOnlineRegistry() {
    ///     try list.export(to: cachePath)
    /// }
    /// ```
    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public func updateUsingOnlineRegistry(cachePolicy: URLRequest.CachePolicy? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            updateUsingOnlineRegistry(cachePolicy: cachePolicy) { updated in
                continuation.resume(returning: updated)
            }
        }
    }

    /// Fetches the latest rules on a background thread and swaps in the new
    /// trie when the response succeeds. Safe to call from any thread.
    ///
    /// Concurrent calls are coalesced — if an update is already in flight,
    /// subsequent calls return immediately without invoking their completion.
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

    /// Writes the current trie bytes to disk in the binary format consumed
    /// by ``InitializerSource/filePath(_:)``. Useful for caching the result
    /// of an online update so the next launch can skip the network round-trip.
    ///
    /// ```swift
    /// let list = await PublicSuffixList.list(from: .onlineRegistry(nil))
    /// let cacheUrl = FileManager.default
    ///     .urls(for: .cachesDirectory, in: .userDomainMask).first!
    ///     .appendingPathComponent("public-suffix-list.trie")
    /// try list.export(to: cacheUrl.path)
    /// ```
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
