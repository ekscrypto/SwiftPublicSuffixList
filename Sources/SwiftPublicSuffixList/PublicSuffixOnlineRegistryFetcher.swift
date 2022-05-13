//
//  PublicSuffixListOnlineRegistryFetcher.swift
//  SwiftPublicSuffixList
//
//  Created by Dave Poirier on 2022-02-19.
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license
//

import Foundation

public class PublicSuffixListOnlineRegistryFetcher {
    
    @available(macOS 10.15.0, iOS 13, tvOS 13, *)
    /// Retrieves the most up-to-date Public Suffix List from https://publicsuffix.org/list/public_suffix_list.dat
    /// - Parameters:
    ///   - logger: Logger to use
    ///   - cachePolicy: URLRequest.CachePolicy to use, leave nil for URLSession default
    /// - Returns: Public Suffix Rules retrieved or nil if the query/decoding failed
    public static func fetch(
        logger: @escaping PublicSuffixList.Logger = PublicSuffixList.logger,
        cachePolicy: URLRequest.CachePolicy?,
        urlRequestHandler: @escaping PublicSuffixList.URLRequestHandler = PublicSuffixList.defaultUrlRequestHandler
    ) async -> [[String]]? {
        
        await withCheckedContinuation({ continuation in
            continuation.resume(returning: fetch(logger: logger, cachePolicy: cachePolicy))
        })
    }
    
    /// Retrieves the most up-to-date Public Suffix List from https://publicsuffix.org/list/public_suffix_list.dat
    ///
    /// - Parameters:
    ///   - logger: Logger to use
    ///   - cachePolicy: URLRequest.CachePolicy to use, leave nil for URLSession default
    /// - Returns: Decoded rules or nil if the online query failed
    ///
    /// WARNING: Will block whichever thread this is dispatched on.  Not allowed to be called from main thread. Consider using the async
    /// version
    ///
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
