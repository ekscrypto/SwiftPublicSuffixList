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
    
    public struct Match {
        let matchedRules: [[String]]
        let prevailingRule: [String]
        let isRestricted: Bool
    }
    
    /// Validate the candidate string follows expected RFC5321 Domain syntax
    /// - Parameters:
    ///   - candidate: String to validate
    ///   - rules: Public Suffix List registry rules to validate against
    /// - Returns: true if domain is not a public suffix AND domain is a subdomain of a defined public suffix AND string follows RFC5321 validation rules; false otherwise
    public static func isUnrestricted(_ candidate: String, rules: [[String]] = PublicSuffixRulesRegistry.rules) -> Bool {
        guard let match = match(candidate, rules: rules) else {
            return false
        }
        
        return !match.isRestricted
    }
    
    public static func match(_ candidate: String, rules: [[String]] = PublicSuffixRulesRegistry.rules) -> Match? {
        
        guard hostPassesGuards(candidate) else { return nil }
        
        let labels = candidate.components(separatedBy: ".")
        guard labels.allSatisfy({ labelPassesGuards($0) }) else { return nil }
        
        let matchedSuffixes: [[String]] = rules.filter {
            hostMatchSuffixRules($0, labels: labels)
        }

        if let exceptionRule = matchedSuffixes.first(where: { $0.first?.hasPrefix("!") ?? false }) {
            return Match(matchedRules: matchedSuffixes,
                         prevailingRule: exceptionRule,
                         isRestricted: false)
        }
        
        if let prevailingRule = matchedSuffixes.sorted(by: { $0.count > $1.count }).first {
            return Match(matchedRules: matchedSuffixes,
                         prevailingRule: prevailingRule,
                         isRestricted: labels.count <= prevailingRule.count)
        }

        precondition(matchedSuffixes.count == 0)
        return nil
    }
        
    private static func labelPassesGuards(_ label: String) -> Bool {
        (1...63).contains(label.count) && // must contain at least 1 character, no more than 63
        !label.hasPrefix("-") && // must not start with hyphen
        !label.hasSuffix("-") // must not end with hyphen
    }
    
    private static func hostPassesGuards(_ candidate: String) -> Bool {
        let disallowedCharacters = CharacterSet(charactersIn: #",~:!@#$%^&'"(){}_*"#)
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        return (1...253).contains(candidate.count) && // cannot be empty and must be no more than 253 characters long
              candidate.rangeOfCharacter(from: disallowedCharacters) == nil && // must not contain invalid characters
              !candidate.hasPrefix(".") && // cannot start with dot
              !candidate.hasSuffix(".") // cannot end with dot
    }
    
    private static func hostMatchSuffixRules(_ rules: [String], labels: [String]) -> Bool {
        guard rules.count > 0,
              labels.count > 0
        else {
            return false
        }
        
        var rulesToEvaluate = rules
        var labelsLeft = labels
        
        while let rule = rulesToEvaluate.last, let label = labelsLeft.last {
            rulesToEvaluate = rulesToEvaluate.dropLast()
            labelsLeft = labelsLeft.dropLast()
            
            if rule.hasPrefix("!") {
                let exceptionRule = String(rule.dropFirst())
                return exceptionRule == label
            }
            
            if rule == "*" || rule == label { continue }
            return false
        }
        return rulesToEvaluate.count == 0
    }
}