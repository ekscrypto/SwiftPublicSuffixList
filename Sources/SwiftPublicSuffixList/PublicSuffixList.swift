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

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A thread-safe class for validating domain names against the Public Suffix List.
///
/// `PublicSuffixList` determines whether a domain is "restricted" (a public suffix like `com` or `co.uk`)
/// or "unrestricted" (a registrable domain like `yahoo.com`).
///
/// ## Overview
///
/// The Public Suffix List is a cross-vendor initiative to provide an accurate list of domain name suffixes.
/// This library allows you to check if a domain should be allowed to set cookies, host websites, or send/receive emails.
///
/// ## Usage
///
/// ```swift
/// // Using static methods with embedded rules
/// if PublicSuffixList.isUnrestricted("yahoo.com") {
///     print("Domain is valid for registration")
/// }
///
/// // Using an instance with custom source
/// let list = await PublicSuffixList.list(from: .onlineRegistry(nil))
/// let isValid = list.isUnrestricted("example.com")
/// ```
///
/// ## Thread Safety
///
/// All public methods are thread-safe. The rules can be updated at runtime using ``updateUsingOnlineRegistry(cachePolicy:completion:)``.
///
/// ## Topics
///
/// ### Creating a Public Suffix List
///
/// - ``list(from:urlRequestHandler:)``
/// - ``init(source:urlRequestHandler:)``
///
/// ### Validating Domains
///
/// - ``isUnrestricted(_:)-7n6op``
/// - ``isUnrestricted(_:rules:)``
/// - ``match(_:rules:)``
///
/// ### Updating Rules
///
/// - ``updateUsingOnlineRegistry(cachePolicy:)-6bqvv``
/// - ``updateUsingOnlineRegistry(cachePolicy:completion:)``
/// - ``export(to:writeOptions:)``
final public class PublicSuffixList {

    /// Completion handler type for URL request operations.
    ///
    /// - Parameters:
    ///   - data: The response data, or `nil` if the request failed.
    ///   - response: The URL response metadata, or `nil` if the request failed.
    ///   - error: An error object if the request failed, or `nil` if successful.
    public typealias URLRequestCompletion = (Data?, URLResponse?, Error?) -> Void

    /// Handler type for performing URL requests.
    ///
    /// This allows custom networking implementations or testing mocks.
    ///
    /// - Parameters:
    ///   - request: The URL request to perform.
    ///   - completion: A completion handler to call with the results.
    public typealias URLRequestHandler = (URLRequest, @escaping URLRequestCompletion) -> Void

    /// Logger function type for diagnostic messages.
    ///
    /// - Parameter message: The message to log.
    public typealias Logger = (String) -> Void

    /// The logger used for diagnostic messages.
    ///
    /// Defaults to `print(_:)`. Set this to a custom function to integrate with your logging system.
    public static var logger: Logger = { print($0) }

    /// The default URL request handler using `URLSession.shared`.
    ///
    /// This handler performs standard HTTP requests using the shared URL session.
    public static let defaultUrlRequestHandler: URLRequestHandler = { request, completion in
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }
    
    /// The data source used to initialize the Public Suffix List rules.
    ///
    /// Use this enum to specify where the suffix rules should be loaded from when creating
    /// a new ``PublicSuffixList`` instance.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Load from the online registry
    /// let list = PublicSuffixList(source: .onlineRegistry(nil))
    ///
    /// // Use custom rules
    /// let customList = PublicSuffixList(source: .rules([["com"], ["co", "uk"]]))
    /// ```
    public enum InitializerSource {

        /// Load rules from a JSON file at the specified path.
        ///
        /// The JSON file should contain an array of string arrays representing domain rules.
        /// Falls back to embedded rules if the file cannot be read or decoded.
        ///
        /// - Parameter path: The file system path to the JSON file.
        case filePath(String)

        /// Use custom rules provided directly.
        ///
        /// - Parameter rules: An array of domain rules, where each rule is an array of domain labels.
        case rules([[String]])

        /// Fetch the latest rules from the official Public Suffix List registry.
        ///
        /// Attempts to download rules from `https://publicsuffix.org/list/public_suffix_list.dat`.
        /// Falls back to embedded rules if the download fails.
        ///
        /// - Parameter cachePolicy: The cache policy for the URL request, or `nil` for default behavior.
        case onlineRegistry(URLRequest.CachePolicy?)

        /// Use the embedded rules bundled with the package.
        ///
        /// This source uses the `registry.json` file included in the package bundle.
        /// The embedded rules may be out of date depending on when the package was last updated.
        case embedded
    }

    /// The result of matching a domain against Public Suffix List rules.
    ///
    /// This struct contains information about which rules matched the domain
    /// and whether the domain is considered restricted (a public suffix itself).
    ///
    /// ## Properties
    ///
    /// - ``matchedRules``: All rules that matched the domain.
    /// - ``prevailingRule``: The most specific rule that applies.
    /// - ``isRestricted``: Whether the domain is a public suffix.
    public struct Match {

        /// All rules that matched the candidate domain.
        ///
        /// This includes all matching rules, not just the prevailing one.
        /// Useful for debugging or understanding the rule matching behavior.
        public let matchedRules: [[String]]

        /// The most specific rule that applies to the domain.
        ///
        /// For exception rules (prefixed with `!`), this is the exception rule.
        /// Otherwise, it's the longest matching rule.
        public let prevailingRule: [String]

        /// Indicates whether the domain is a public suffix and should be restricted.
        ///
        /// - `true`: The domain is a public suffix (e.g., `com`, `co.uk`) and should not
        ///   be allowed to set cookies or be directly registered.
        /// - `false`: The domain is a registrable domain (e.g., `yahoo.com`) or an exception
        ///   to a public suffix rule.
        public let isRestricted: Bool
    }
    
    /// The current Public Suffix List rules.
    ///
    /// Rules are stored as arrays of domain labels in reverse order (TLD first).
    /// This property is thread-safe for both reading and writing.
    ///
    /// ## Rule Format
    ///
    /// ```swift
    /// [
    ///   ["com"],                              // Matches .com TLD
    ///   ["blockedDomain", "com"],             // Matches blockedDomain.com
    ///   ["*", "blockAllSubdomains", "com"],   // Wildcard for *.blockAllSubdomains.com
    ///   ["!isAllowed", "blockedAllSubdomains", "com"]  // Exception rule
    /// ]
    /// ```
    ///
    /// ## Rule Types
    ///
    /// - **Standard rules**: Match exact domain labels (e.g., `["com"]` matches `.com`)
    /// - **Wildcard rules**: Use `*` to match any label (e.g., `["*", "uk"]` matches `*.uk`)
    /// - **Exception rules**: Prefix with `!` to exclude from restriction (e.g., `["!www", "gov", "us"]`
    ///   allows `www.gov.us` even if `["*", "gov", "us"]` would restrict it)
    public var rules: [[String]] {
        set {
            defer {
                accessLock.unlock()
            }
            accessLock.lock()
            unsafeRules = newValue
        }
        get {
            defer {
                accessLock.unlock()
            }
            accessLock.lock()
            return unsafeRules
        }
    }
    private var unsafeRules: [[String]]
    private let urlRequestHandler: URLRequestHandler
    private let accessLock: NSLock
    private var updateThread: Thread?
    
    /// Asynchronously creates a new `PublicSuffixList` instance from the specified source.
    ///
    /// This is the recommended way to create a `PublicSuffixList` when using async/await,
    /// as it handles the potentially long initialization time without blocking the main thread.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let list = await PublicSuffixList.list(from: .onlineRegistry(nil))
    /// if list.isUnrestricted("example.com") {
    ///     print("Domain is valid")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - source: The data source for loading rules. Defaults to ``InitializerSource/embedded``.
    ///   - urlRequestHandler: The handler for performing URL requests. Defaults to ``defaultUrlRequestHandler``.
    /// - Returns: A configured `PublicSuffixList` instance.
    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public static func list(
        from source: InitializerSource = .embedded,
        urlRequestHandler: @escaping URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler
    ) async -> PublicSuffixList {
        await withCheckedContinuation({ continuation in
            let list = PublicSuffixList(source: source, urlRequestHandler: urlRequestHandler)
            continuation.resume(returning: list)
        })
    }
    
    /// Creates a new `PublicSuffixList` instance using the specified source.
    ///
    /// - Important: Except for ``InitializerSource/rules(_:)``, all other sources may block
    ///   the current thread temporarily. Initialization is not allowed on the main thread
    ///   to prevent UI freezes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // On a background thread
    /// DispatchQueue.global().async {
    ///     let list = PublicSuffixList(source: .embedded)
    ///     // Use the list...
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - source: The data source for loading rules. Defaults to ``InitializerSource/embedded``.
    ///   - urlRequestHandler: The handler for performing URL requests. Defaults to ``defaultUrlRequestHandler``.
    public init(source: InitializerSource = .embedded,
         urlRequestHandler: @escaping URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler
    ) {
        switch source {
        case .rules(let customRules):
            self.unsafeRules = customRules
            
        case .onlineRegistry(let cachePolicy):
            precondition(!Thread.isMainThread, "\(Self.self) May not be initialized on main thread due to long loading times")
            if let fetchedRules = PublicSuffixListOnlineRegistryFetcher.fetch(
                logger: Self.logger,
                cachePolicy: cachePolicy,
                urlRequestHandler: urlRequestHandler) {
                self.unsafeRules = fetchedRules
            } else {
                self.unsafeRules = PublicSuffixRulesRegistry.rules
            }

        case .filePath(let path):
            precondition(!Thread.isMainThread, "\(Self.self) May not be initialized on main thread due to long loading times")
            self.unsafeRules = Self.rulesFromFile(path: path) ?? PublicSuffixRulesRegistry.rules

        case .embedded:
            precondition(!Thread.isMainThread, "\(Self.self) May not be initialized on main thread due to long loading times")
            self.unsafeRules = PublicSuffixRulesRegistry.rules
        }
        self.accessLock = NSLock()
        self.urlRequestHandler = urlRequestHandler
    }
    
    /// Attempt to decode [[String]] JSON file from the file path provided
    /// - Parameter path: File path where the JSON file is expected to be
    /// - Returns: Decoded rules or nil if the file is missing or decoding failed
    private static func rulesFromFile(path: String) -> [[String]]? {
        do {
            let fileContent = try Data(contentsOf: URL(fileURLWithPath: path))
            let rules = try JSONDecoder().decode([[String]].self, from: fileContent)
            return rules
        } catch {
            Self.logger("\(Self.self) WARNING: Failed to load Public Suffix List from specified path")
            return nil
        }
    }
    
    /// Asynchronously updates the rules from the official Public Suffix List registry.
    ///
    /// Downloads the latest rules from `https://publicsuffix.org/list/public_suffix_list.dat`
    /// and replaces the current ``rules``.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let list = await PublicSuffixList.list()
    /// let success = await list.updateUsingOnlineRegistry()
    /// if success {
    ///     try list.export(to: "/path/to/cache.json")
    /// }
    /// ```
    ///
    /// - Parameter cachePolicy: The cache policy for the URL request, or `nil` for default behavior.
    /// - Returns: `true` if the update succeeded, `false` otherwise.
    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public func updateUsingOnlineRegistry(cachePolicy: URLRequest.CachePolicy? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            updateUsingOnlineRegistry(cachePolicy: cachePolicy) { updated in
                continuation.resume(returning: updated)
            }
        }
    }
    
    /// Updates the rules from the official Public Suffix List registry with a completion handler.
    ///
    /// Downloads the latest rules from `https://publicsuffix.org/list/public_suffix_list.dat`
    /// on a background thread and calls the completion handler when finished.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let list = PublicSuffixList(source: .embedded)
    /// list.updateUsingOnlineRegistry { success in
    ///     if success {
    ///         print("Rules updated successfully")
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - cachePolicy: The cache policy for the URL request, or `nil` for default behavior.
    ///   - completion: A closure called when the update completes. Receives `true` if successful.
    public func updateUsingOnlineRegistry(
        cachePolicy: URLRequest.CachePolicy? = nil,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard updateThread == nil else {
            return
        }
        let requestHandler = self.urlRequestHandler
        updateThread = Thread { [weak self] in
            var success: Bool = false
            if let onlineRules = PublicSuffixListOnlineRegistryFetcher.fetch(logger: Self.logger, cachePolicy: cachePolicy, urlRequestHandler: requestHandler) {
                self?.rules = onlineRules
                Self.logger("\(Self.self) Public Suffix List updated")
                success = true
            }
            completion(success)
            self?.updateThread = nil
        }
        updateThread?.start()
    }
    
    /// Exports the current rules to a JSON file.
    ///
    /// Encodes the current ``rules`` as JSON and writes them to the specified file path.
    /// This allows caching downloaded rules for offline use or faster startup.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let list = await PublicSuffixList.list(from: .onlineRegistry(nil))
    /// let cachePath = FileManager.default
    ///     .urls(for: .cachesDirectory, in: .userDomainMask).first!
    ///     .appendingPathComponent("suffix-rules.json").path
    /// try list.export(to: cachePath)
    /// ```
    ///
    /// - Parameters:
    ///   - path: The file system path where the JSON file will be written.
    ///   - writeOptions: Options for writing the data. Defaults to no options.
    /// - Throws: An error if the file cannot be written.
    public func export(
        to path: String,
        writeOptions: Data.WritingOptions = []
    ) throws {
        let encodedRules = try! JSONEncoder().encode(rules)
        let url = URL(fileURLWithPath: path)
        try encodedRules.write(to: url, options: writeOptions)
    }
    
    /// Checks whether a domain is unrestricted (not a public suffix).
    ///
    /// Validates that the domain follows RFC5321 syntax and is not a public suffix itself.
    /// A domain is unrestricted if it's a registrable domain (like `yahoo.com`) rather than
    /// a public suffix (like `com` or `co.uk`).
    ///
    /// - Note: This operation may be computationally expensive with large rule sets.
    ///   Consider using the async variant or running on a background thread.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let list = PublicSuffixList(source: .embedded)
    /// list.isUnrestricted("yahoo.com")  // true
    /// list.isUnrestricted("com")        // false
    /// ```
    ///
    /// - Parameter candidate: The domain string to validate.
    /// - Returns: `true` if the domain is valid and not a public suffix; `false` otherwise.
    public func isUnrestricted(_ candidate: String) -> Bool {
        Self.isUnrestricted(candidate, rules: self.rules)
    }

    /// Asynchronously checks whether a domain is unrestricted.
    ///
    /// This is the async variant of ``isUnrestricted(_:)-7n6op`` that runs the
    /// validation without blocking the current context.
    ///
    /// - Parameter candidate: The domain string to validate.
    /// - Returns: `true` if the domain is valid and not a public suffix; `false` otherwise.
    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public func isUnrestricted(_ candidate: String) async -> Bool {
        await withCheckedContinuation({ continuation in
            let unrestricted = Self.isUnrestricted(candidate)
            continuation.resume(returning: unrestricted)
        })
    }
    
    /// Checks whether a domain is unrestricted using the specified rules.
    ///
    /// This static method allows validation against custom rules without creating
    /// a `PublicSuffixList` instance. By default, it uses the embedded registry rules.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Using default embedded rules
    /// PublicSuffixList.isUnrestricted("yahoo.com")  // true
    ///
    /// // Using custom rules
    /// PublicSuffixList.isUnrestricted("test.example", rules: [["example"]])  // true
    /// ```
    ///
    /// - Parameters:
    ///   - candidate: The domain string to validate.
    ///   - rules: The rules to validate against. Defaults to ``PublicSuffixRulesRegistry/rules``.
    /// - Returns: `true` if the domain is valid and not a public suffix; `false` otherwise.
    public static func isUnrestricted(
        _ candidate: String,
        rules: [[String]] = PublicSuffixRulesRegistry.rules
    ) -> Bool {
        guard let match = match(candidate, rules: rules) else {
            return false
        }

        return !match.isRestricted
    }

    /// Matches a domain against Public Suffix List rules.
    ///
    /// Returns detailed information about which rules matched and whether the domain
    /// is restricted. Returns `nil` if the domain is invalid or doesn't match any rules.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let match = PublicSuffixList.match("yahoo.com") {
    ///     print("Restricted: \(match.isRestricted)")      // false
    ///     print("Rule: \(match.prevailingRule)")          // ["com"]
    /// }
    ///
    /// // Using custom rules with wildcards
    /// let rules = [["*", "com"], ["!yahoo", "com"]]
    /// if let match = PublicSuffixList.match("yahoo.com", rules: rules) {
    ///     print("Restricted: \(match.isRestricted)")      // false (exception rule applies)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - candidate: The domain string to match.
    ///   - rules: The rules to match against. Defaults to ``PublicSuffixRulesRegistry/rules``.
    /// - Returns: A ``Match`` containing match details, or `nil` if the domain is invalid or unmatched.
    public static func match(
        _ candidate: String,
        rules: [[String]] = PublicSuffixRulesRegistry.rules
    ) -> Match? {
        PublicSuffixMatcher.match(candidate, rules: rules)
    }
}
