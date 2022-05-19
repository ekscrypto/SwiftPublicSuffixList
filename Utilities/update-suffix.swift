//
//  update-suffix.swift
//  SwiftEmailValidator
//
//  Created by Dave Poirier on 2022-01-22
//  Copyrights (C) 2022, Dave Poirier.  Distributed under MIT license

import Foundation

let publicSuffixUrl = URL(string: "https://publicsuffix.org/list/public_suffix_list.dat")!
guard let publicSuffixData = try? Data(contentsOf: publicSuffixUrl),
      let publicSuffixAsString = String(data: publicSuffixData, encoding: .utf8)
else {
    print("Failed to download and decode public_suffix_list.dat")
    exit(-1)
}

let publicSuffixRulesRegistry: [[String]] = publicSuffixAsString
    .components(separatedBy: .newlines)
    .filter({ !$0.hasPrefix("//") && !$0.isEmpty })
    .map({ $0.components(separatedBy: ".") })

guard let publicSuffixSwiftData: Data = try? JSONEncoder().encode(publicSuffixRulesRegistry) else {
    fatalError("Unable to generate Swift representation, aborted.")
}

let generatedSwiftFileUrl = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .deletingLastPathComponent() // get out of the Utilities folder
    .appendingPathComponent("Sources")
    .appendingPathComponent("SwiftPublicSuffixList")
    .appendingPathComponent("registry.json")

do {
    try publicSuffixSwiftData.write(to: generatedSwiftFileUrl)
    print("Generated file stored at \(generatedSwiftFileUrl)")
} catch {
    print("Failed to generate output file at \(generatedSwiftFileUrl): \(error)")
}
