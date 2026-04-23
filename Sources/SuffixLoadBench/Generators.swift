import Foundation

enum Generators {

    /// Read the shipping registry.json from the library target's bundled resource folder.
    static func loadSourceRules() throws -> [[String]] {
        let sourcePath = resolveSourceRegistryJsonPath()
        let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        return try JSONDecoder().decode([[String]].self, from: data)
    }

    static func resolveSourceRegistryJsonPath() -> String {
        // The file we want to treat as the canonical source.
        let candidates = [
            "Sources/SwiftPublicSuffixList/registry.json",
            "../Sources/SwiftPublicSuffixList/registry.json",
            "../../Sources/SwiftPublicSuffixList/registry.json"
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return candidates[0]
    }

    static func outputDir() -> String {
        let candidates = [
            "Sources/SuffixLoadBench/Resources",
            "../Sources/SuffixLoadBench/Resources",
            "../../Sources/SuffixLoadBench/Resources"
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return candidates[0]
    }

    static func writeJSONCopy(_ rules: [[String]]) throws -> String {
        let path = outputDir() + "/registry.json"
        let data = try JSONEncoder().encode(rules)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func writeBinaryPlist(_ rules: [[String]]) throws -> String {
        let path = outputDir() + "/registry.plist"
        let data = try PropertyListSerialization.data(
            fromPropertyList: rules,
            format: .binary,
            options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Simple binary:
    ///   u32 ruleCount
    ///   per rule: u8 labelCount, then per label: u8 length, utf8 bytes
    static func writeSimpleBinary(_ rules: [[String]]) throws -> String {
        let path = outputDir() + "/registry.bin"
        var out = Data()
        out.reserveCapacity(rules.reduce(0) { $0 + 1 + $1.reduce(0) { $0 + 1 + $1.utf8.count } } + 4)
        out.appendLE(UInt32(rules.count))
        for rule in rules {
            precondition(rule.count <= 255)
            out.append(UInt8(rule.count))
            for label in rule {
                let utf8 = Array(label.utf8)
                precondition(utf8.count <= 255)
                out.append(UInt8(utf8.count))
                out.append(contentsOf: utf8)
            }
        }
        try out.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Deduplicated binary:
    ///   u32 uniqueLabelCount
    ///   per label: u8 length, utf8 bytes
    ///   u32 ruleCount
    ///   per rule: u8 labelCount, then labelCount × u16 label index (little-endian)
    static func writeDedupBinary(_ rules: [[String]]) throws -> String {
        let path = outputDir() + "/registry-dedup.bin"
        var labelOrder: [String] = []
        var labelIndex: [String: UInt16] = [:]
        for rule in rules {
            for label in rule {
                if labelIndex[label] == nil {
                    precondition(labelOrder.count < 65_535, "label table exceeds u16 range")
                    labelIndex[label] = UInt16(labelOrder.count)
                    labelOrder.append(label)
                }
            }
        }
        var out = Data()
        out.appendLE(UInt32(labelOrder.count))
        for label in labelOrder {
            let utf8 = Array(label.utf8)
            precondition(utf8.count <= 255)
            out.append(UInt8(utf8.count))
            out.append(contentsOf: utf8)
        }
        out.appendLE(UInt32(rules.count))
        for rule in rules {
            precondition(rule.count <= 255)
            out.append(UInt8(rule.count))
            for label in rule {
                out.appendLE(labelIndex[label]!)
            }
        }
        try out.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Binary trie — walked in place (strategy 7).
    static func writeTrie(_ rules: [[String]]) throws -> String {
        let path = outputDir() + "/registry.trie"
        let root = TrieBuilder.build(rules: rules)
        let data = TrieSerializer.serialize(root: root, ruleCount: rules.count)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Plain text: one rule per line, labels joined by '.'.
    /// NOTE: labels never contain '.', so this is unambiguous.
    static func writeText(_ rules: [[String]]) throws -> String {
        let path = outputDir() + "/registry.txt"
        var buffer = ""
        buffer.reserveCapacity(rules.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count + 1 } })
        for rule in rules {
            buffer.append(rule.joined(separator: "."))
            buffer.append("\n")
        }
        try buffer.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Swift source containing a single String literal with the compact text
    /// format: one rule per line, labels joined by '.'.
    ///
    /// A single literal string is O(1) for the type checker — building a
    /// 10k-element Array<Array<String>> literal is not.
    static func writeSwiftLiteral(_ rules: [[String]]) throws -> String {
        let path = "Sources/SuffixLoadBench/GeneratedRules.swift"
        let outPath = FileManager.default.fileExists(atPath: path) ? path :
            (FileManager.default.fileExists(atPath: "../" + path) ? "../" + path : path)
        var payload = ""
        payload.reserveCapacity(rules.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count + 1 } })
        for rule in rules {
            payload.append(rule.joined(separator: "."))
            payload.append("\n")
        }
        var buffer = "// Generated by SuffixLoadBench generate. Do not edit.\n\n"
        buffer += "enum GeneratedRules {\n"
        buffer += "    /// One rule per line, labels joined by '.' — no escapes needed\n"
        buffer += "    /// because PSL labels never contain '.' or '\"' or '\\\\'.\n"
        buffer += "    static let raw: StaticString = \"\"\"\n"
        buffer += payload
        buffer += "\"\"\"\n"
        buffer += "}\n"
        try buffer.write(toFile: outPath, atomically: true, encoding: .utf8)
        return outPath
    }
}

extension Data {
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
