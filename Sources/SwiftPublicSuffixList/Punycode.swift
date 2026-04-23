//
//  Punycode.swift
//  SwiftPublicSuffixList
//
//  RFC 3492 Punycode encoder used to normalize IDN labels to ACE form
//  (the `xn--…` shape) at build time so the serialized trie contains
//  only ASCII label bytes. Callers must supply hostnames in the same
//  form — i.e. decoded to ACE before `match(_:)` / `isUnrestricted(_:)`.
//
//  This is *encoder only*. We never need to decode ACE back to Unicode
//  because matching never exposes label bytes as strings.
//

import Foundation

enum Punycode {
    private static let base: UInt32 = 36
    private static let tmin: UInt32 = 1
    private static let tmax: UInt32 = 26
    private static let skew: UInt32 = 38
    private static let damp: UInt32 = 700
    private static let initialBias: UInt32 = 72
    private static let initialN: UInt32 = 0x80

    /// Converts `label` to its ACE form.
    ///
    /// - Pure-ASCII labels (no scalar ≥ 0x80) are returned verbatim, since
    ///   ACE is a superset of ASCII LDH. Case is preserved.
    /// - Labels containing any non-ASCII scalar are RFC 3492 Punycode-encoded
    ///   and prefixed with `xn--`.
    ///
    /// The PSL source file is expected to already be in canonical (NFC,
    /// lowercased) form — this function does not normalize case or apply
    /// NFC. Feed it already-canonicalized labels.
    static func toACE(_ label: String) -> String {
        var hasNonASCII = false
        for scalar in label.unicodeScalars where scalar.value >= 0x80 {
            hasNonASCII = true
            break
        }
        if !hasNonASCII { return label }
        let scalars = label.unicodeScalars.map { $0.value }
        return "xn--" + encode(scalars)
    }

    private static func adapt(delta: UInt32, numPoints: UInt32, firstTime: Bool) -> UInt32 {
        var d = firstTime ? (delta / damp) : (delta / 2)
        d = d + (d / numPoints)
        var k: UInt32 = 0
        while d > ((base - tmin) * tmax) / 2 {
            d = d / (base - tmin)
            k = k + base
        }
        return k + (((base - tmin + 1) * d) / (d + skew))
    }

    /// Digit 0..35 → ASCII: 0..25 → 'a'..'z', 26..35 → '0'..'9'.
    private static func digit(_ d: UInt32) -> UInt8 {
        if d < 26 { return UInt8(0x61 + d) }
        return UInt8(0x30 + d - 26)
    }

    private static func encode(_ input: [UInt32]) -> String {
        var n: UInt32 = initialN
        var delta: UInt32 = 0
        var bias: UInt32 = initialBias
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)

        var h: UInt32 = 0
        var b: UInt32 = 0
        for cp in input where cp < 0x80 {
            output.append(UInt8(cp))
            h += 1
            b += 1
        }
        if b > 0 {
            output.append(0x2D) // '-'
        }

        let total = UInt32(input.count)
        while h < total {
            var m: UInt32 = .max
            for cp in input where cp >= n && cp < m {
                m = cp
            }
            delta = delta + (m - n) * (h + 1)
            n = m
            for cp in input {
                if cp < n { delta += 1 }
                if cp == n {
                    var q = delta
                    var k = base
                    while true {
                        let t: UInt32
                        if k <= bias + tmin { t = tmin }
                        else if k >= bias + tmax { t = tmax }
                        else { t = k - bias }
                        if q < t { break }
                        output.append(digit(t + ((q - t) % (base - t))))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta: delta, numPoints: h + 1, firstTime: h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(bytes: output, encoding: .ascii)!
    }
}
