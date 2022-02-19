//
//  PublicSuffixMatcher.swift
//  SwiftPublicSuffixList
//
//  Created by Dave Poirier on 2022-02-19.
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license
//

import Foundation

internal class PublicSuffixMatcher {
    
    static func match(_ candidate: String, rules: [[String]] = PublicSuffixRulesRegistry.rules) -> PublicSuffixList.Match? {
        
        guard isHost(candidate) else { return nil }
        
        let labels = candidate.components(separatedBy: ".")
        guard labels.allSatisfy({ isLabel($0) }) else { return nil }
        
        let matchedSuffixes: [[String]] = rules.filter { match($0, labels: labels) }
        
        if let exceptionRule = matchedSuffixes.first(where: { $0.first?.hasPrefix("!") ?? false }) {
            return PublicSuffixList.Match(matchedRules: matchedSuffixes,
                                          prevailingRule: exceptionRule,
                                          isRestricted: false)
        }
        
        if let prevailingRule = matchedSuffixes.sorted(by: { $0.count > $1.count }).first {
            return PublicSuffixList.Match(matchedRules: matchedSuffixes,
                                          prevailingRule: prevailingRule,
                                          isRestricted: labels.count <= prevailingRule.count)
        }
        
        assert(matchedSuffixes.count == 0)
        return nil
    }
    
    private static func isLabel(_ label: String) -> Bool {
        (1...63).contains(label.count) && // must contain at least 1 character, no more than 63
        !label.hasPrefix("-") && // must not start with hyphen
        !label.hasSuffix("-") // must not end with hyphen
    }
    
    private static func isHost(_ candidate: String) -> Bool {
        let disallowedCharacters = CharacterSet(charactersIn: #",~:!@#$%^&'"(){}_*"#)
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        return (1...253).contains(candidate.count) && // cannot be empty and must be no more than 253 characters long
        candidate.rangeOfCharacter(from: disallowedCharacters) == nil && // must not contain invalid characters
        !candidate.hasPrefix(".") && // cannot start with dot
        !candidate.hasSuffix(".") // cannot end with dot
    }

    private static func match(_ rules: [String], labels: [String]) -> Bool {
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
