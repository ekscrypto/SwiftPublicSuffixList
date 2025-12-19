//
//  PublicSuffixListOnlineRegistryFetcher.swift
//  SwiftPublicSuffixList
//
//  Created by Dave Poirier on 2022-02-19.
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches the latest Public Suffix List rules from the official online registry.
///
/// This class downloads and parses the Public Suffix List from
/// `https://publicsuffix.org/list/public_suffix_list.dat`.
///
/// ## Overview
///
/// Use this class to fetch the most up-to-date rules directly from the source.
/// The fetcher handles downloading, parsing, and converting the text format
/// to the internal rule representation.
///
/// ## Usage
///
/// ```swift
/// // Async fetch
/// if let rules = await PublicSuffixListOnlineRegistryFetcher.fetch(cachePolicy: nil) {
///     print("Fetched \(rules.count) rules")
/// }
///
/// // Synchronous fetch (must be called from background thread)
/// DispatchQueue.global().async {
///     if let rules = PublicSuffixListOnlineRegistryFetcher.fetch(cachePolicy: .reloadIgnoringLocalCacheData) {
///         print("Fetched \(rules.count) rules")
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// The synchronous ``fetch(logger:cachePolicy:urlRequestHandler:)-5f3dv`` method blocks the calling thread
/// and must not be called from the main thread. Use the async variant when possible.
public class PublicSuffixListOnlineRegistryFetcher {

    /// Asynchronously fetches the latest Public Suffix List rules.
    ///
    /// Downloads and parses rules from `https://publicsuffix.org/list/public_suffix_list.dat`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let rules = await PublicSuffixListOnlineRegistryFetcher.fetch(cachePolicy: nil) {
    ///     // Use the fetched rules
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - logger: A function for logging diagnostic messages. Defaults to ``PublicSuffixList/logger``.
    ///   - cachePolicy: The cache policy for the URL request, or `nil` for default behavior.
    ///   - urlRequestHandler: The handler for performing URL requests. Defaults to ``PublicSuffixList/defaultUrlRequestHandler``.
    /// - Returns: The fetched rules, or `nil` if the fetch or parsing failed.
    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    public static func fetch(
        logger: @escaping PublicSuffixList.Logger = PublicSuffixList.logger,
        cachePolicy: URLRequest.CachePolicy?,
        urlRequestHandler: @escaping PublicSuffixList.URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler
    ) async -> [[String]]? {

        await withCheckedContinuation({ continuation in
            continuation.resume(returning: fetch(logger: logger, cachePolicy: cachePolicy))
        })
    }

    /// Synchronously fetches the latest Public Suffix List rules.
    ///
    /// Downloads and parses rules from `https://publicsuffix.org/list/public_suffix_list.dat`.
    ///
    /// - Important: This method blocks the calling thread and must not be called from the main thread.
    ///   Use the async variant ``fetch(logger:cachePolicy:urlRequestHandler:)-9w6ug`` when possible.
    ///
    /// ## Example
    ///
    /// ```swift
    /// DispatchQueue.global().async {
    ///     if let rules = PublicSuffixListOnlineRegistryFetcher.fetch(cachePolicy: nil) {
    ///         // Use the fetched rules
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - logger: A function for logging diagnostic messages. Defaults to ``PublicSuffixList/logger``.
    ///   - cachePolicy: The cache policy for the URL request, or `nil` for default behavior.
    ///   - urlRequestHandler: The handler for performing URL requests. Defaults to ``PublicSuffixList/defaultUrlRequestHandler``.
    /// - Returns: The fetched rules, or `nil` if the fetch or parsing failed.
    public static func fetch(
        logger: @escaping PublicSuffixList.Logger = PublicSuffixList.logger,
        cachePolicy cachePolicyOrNil: URLRequest.CachePolicy?,
        urlRequestHandler: PublicSuffixList.URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler
    ) -> [[String]]? {
        
        precondition(!Thread.isMainThread)
        
        var onlineRules: [[String]]?
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        let publicSuffixUrl: URL = URL(string: "https://publicsuffix.org/list/public_suffix_list.dat")!
        var request = URLRequest(url: publicSuffixUrl)
        if let cachePolicy = cachePolicyOrNil {
            request.cachePolicy = cachePolicy
        }
        urlRequestHandler(request) { dataOrNil, urlResponseOrNil, errorOrNil in
            guard let response = urlResponseOrNil,
                  let data = dataOrNil
            else {
                logger("Failed to download public suffix list. Error: \(errorOrNil?.localizedDescription ?? "")")
                return
            }
            onlineRules = Self.rules(data: data, response: response, logger: logger)
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
        return onlineRules
    }
    
    private static func rules(
        data: Data,
        response: URLResponse,
        logger: (String) -> Void
    ) -> [[String]]? {
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            logger("Non-successful response received from server for Public List Suffix")
            return nil
        }
        
        guard let listAsString = String(data: data, encoding: .utf8) else {
            logger("Public Suffix could not be decoded as valid UTF-8 string")
            return nil
        }
        
        let rules: [[String]] = listAsString
            .components(separatedBy: .newlines)
            .filter({ !$0.hasPrefix("//") && !$0.isEmpty })
            .map({ $0.components(separatedBy: ".") })
        return rules
    }
}
