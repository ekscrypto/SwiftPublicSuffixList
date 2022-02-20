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

final public class PublicSuffixList {
    
    public typealias URLRequestCompletion = (Data?, URLResponse?, Error?) -> Void
    public typealias URLRequestHandler = (URLRequest, @escaping URLRequestCompletion) -> Void
    public typealias Logger = (String) -> Void
    public static var logger: Logger = { print($0) }
    
    public static let defaultUrlRequestHandler: URLRequestHandler = { request, completion in
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }
    
    /// Specify the data soure to use to initialize the PublicSuffixList
    ///
    /// .embedded - Use the default values as included in the SwiftPublicSuffixList package (may be out of date)
    /// .rules([[String]]) - Use the custom values specified
    /// .onlineRegistry - Attempt to retrieve the latest copy from the online registry, fallback to .embedded if query fails
    /// .filePath(String) - Attempt to decode JSON file from file path specified or fallback to .embedded if file doesn't exist or cannot be decoded.  Expects [[String]] JSON file
    ///
    public enum InitializerSource {
        case filePath(String)
        case rules([[String]])
        case onlineRegistry(URLRequest.CachePolicy?)
        case embedded
    }
    
    /// Data type returned by the PublicSuffixList.match functions to provide information about the most closely matched rule
    public struct Match {
        let matchedRules: [[String]]
        let prevailingRule: [String]
        let isRestricted: Bool
    }
    
    /// Current applicable rules.  Expected format:
    ///
    /// [
    ///   ["com"],
    ///   ["blockedDomain", "com"],
    ///   ["*", "blockAllSubdomains", "com"],
    ///   ["!isAllowed","blockedAllSubdomains", "com"]
    /// ]
    ///
    /// Entries starting with "!" are exceptions that are not to be treated as a public suffix even if other rules
    /// would have marked it as a public suffix.  ["!www", "gov", "us"] would not restrict www.gov.us as a public suffix
    /// even if an entry of ["*","gov","us"] would be defined elsewhere.
    ///
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
    
    /// Asynchronously generate a PublicSuffixList instance initialized from the source specified
    /// - Parameter source: Source to use
    /// - Returns: PublicSuffixList instance
    @available(macOS 10.15.0, *)
    public static func list(
        from source: InitializerSource = .embedded,
        urlRequestHandler: @escaping URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler
    ) async -> PublicSuffixList {
        await withCheckedContinuation({ continuation in
            let list = PublicSuffixList(source: source, urlRequestHandler: urlRequestHandler)
            continuation.resume(returning: list)
        })
    }
    
    /// Create a new instane of PublicSuffixList using the specified source
    /// - Parameter source: Except for .rules() source, all other sources may block the current thread temporarily and will not be allowed to run on the main thread (for your own good)
    init(source: InitializerSource = .embedded,
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
    
    @available(macOS 10.15.0, *)
    /// Attempts to update the Public Suffix Rules using the official list at https://publicsuffix.org/list/public_suffix_list.dat
    /// - Parameter cachePolicy: URLRequest.CachePolicy to use, or nil to use URLSession default
    /// - Returns: True if succeeded, false otherwise
    public func updateUsingOnlineRegistry(cachePolicy: URLRequest.CachePolicy? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            updateUsingOnlineRegistry(cachePolicy: cachePolicy) { updated in
                continuation.resume(returning: updated)
            }
        }
    }
    
    /// Attempts to update the Public Suffix Rules using the official list at https://publicsuffix.org/list/public_suffix_list.dat
    /// - Parameters:
    ///   - cachePolicy: URLRequest.CachePolicy to use, or nil to use URLSession default
    ///   - completion: Closure to call when completed, will receive True if succeeded and False otherwise
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
    
    /// Encode the Public Suffix Rules into a JSON object and store it at the specified file path
    /// - Parameters:
    ///   - path: File path where to store the resulting JSON file
    ///   - writeOptions: Data.WriteOptions to use
    public func export(
        to path: String,
        writeOptions: Data.WritingOptions = []
    ) throws {
        let encodedRules = try! JSONEncoder().encode(rules)
        let url = URL(fileURLWithPath: path)
        try encodedRules.write(to: url, options: writeOptions)
    }
    
    /// Validate the candidate string follows expected RFC5321 Domain syntax
    /// - Parameters:
    ///   - candidate: String to validate
    /// - Returns: true if domain is not a public suffix AND domain is a subdomain of a defined public suffix AND string follows RFC5321 validation rules; false otherwise
    ///
    /// WARNING: Depending on the number of active rules and your device, this function may be computationally expensive.  If possible run from a background thread or use the async variant
    public func isUnrestricted(_ candidate: String) -> Bool {
        Self.isUnrestricted(candidate, rules: self.rules)
    }

    @available(macOS 10.15.0, *)
    /// Validate the candidate string follows expected RFC5321 Domain syntax
    /// - Parameters:
    ///   - candidate: String to validate
    /// - Returns: true if domain is not a public suffix AND domain is a subdomain of a defined public suffix AND string follows RFC5321 validation rules; false otherwise
    ///
    public func isUnrestricted(_ candidate: String) async -> Bool {
        await withCheckedContinuation({ continuation in
            let unrestricted = Self.isUnrestricted(candidate)
            continuation.resume(returning: unrestricted)
        })
    }
    
    /// Validate the candidate string follows expected RFC5321 Domain syntax
    /// - Parameters:
    ///   - candidate: String to validate
    ///   - rules: Public Suffix List registry rules to validate against
    /// - Returns: true if domain is not a public suffix AND domain is a subdomain of a defined public suffix AND string follows RFC5321 validation rules; false otherwise
    public static func isUnrestricted(
        _ candidate: String,
        rules: [[String]] = PublicSuffixRulesRegistry.rules
    ) -> Bool {
        guard let match = match(candidate, rules: rules) else {
            return false
        }
        
        return !match.isRestricted
    }
    
    /// Identify the Public Suffix Rule most closely matching the host/domain specified
    /// - Parameters:
    ///   - candidate: Host/Domain string to match
    ///   - rules: Rules to validate against
    /// - Returns: Closest matched rule or nil if host/domain is invalid or not matching any rule
    public static func match(
        _ candidate: String,
        rules: [[String]] = PublicSuffixRulesRegistry.rules
    ) -> Match? {
        PublicSuffixMatcher.match(candidate, rules: rules)
    }
}
