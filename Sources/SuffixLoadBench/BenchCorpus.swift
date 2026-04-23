import Foundation

/// Candidate domains for the match-phase benchmark. A representative mix:
/// - registrable domains under common and uncommon TLDs
/// - bare public suffixes (should be restricted)
/// - wildcard-matched suffixes (e.g. *.ck, *.kw)
/// - exception-matched suffixes (e.g. www.ck, city.kobe.jp)
/// - invalid syntax
/// - IDN punycode and IDN UTF-8
/// - long deeply-nested FQDNs
enum BenchCorpus {
    static let candidates: [String] = [
        // Common registrable domains
        "yahoo.com", "google.com", "github.com", "apple.com", "example.org",
        "cloudflare.com", "openai.com", "wikipedia.org", "microsoft.com",
        "mail.yahoo.com", "docs.google.com", "api.github.com",
        "a.b.c.d.deeply.nested.example.com",

        // Country-specific
        "bbc.co.uk", "police.uk", "britishmuseum.ac.uk", "amazon.co.jp",
        "sony.co.jp", "taobao.com.cn", "naver.co.kr", "sbb.ch",
        "lemonde.fr", "www.gouv.fr", "spiegel.de", "bundestag.de",
        "korea.kr", "metro.seoul.kr", "tokyo.jp", "city.kobe.jp",

        // Public suffixes themselves (should be restricted)
        "com", "org", "net", "co.uk", "co.jp", "com.br", "ac.uk",

        // Wildcards: *.ck  *.kw  *.platform.sh
        "foo.ck", "service.kw", "app.platform.sh",

        // Exceptions
        "www.ck",

        // Mixed depths
        "a.example.com", "a.b.example.com", "a.b.c.example.com",

        // Edge cases
        "localhost", "foo", "bar.invalid-tld",

        // Invalid syntax
        "", ".com", "com.", "foo..bar", "-dash.com", "dash-.com",
        "way.too.long.example.\(String(repeating: "a", count: 64)).com",

        // IDN
        "公司.cn", "xn--55qx5d.cn", "москва.ru", "xn--80adxhks.ru"
    ]
}
