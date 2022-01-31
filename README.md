![swift workflow](https://github.com/ekscrypto/SwiftPublicSuffixList/actions/workflows/swift.yml/badge.svg) [![codecov](https://codecov.io/gh/ekscrypto/SwiftPublicSuffixList/branch/main/graph/badge.svg?token=W9KO1BG8S0)](https://codecov.io/gh/ekscrypto/SwiftPublicSuffixList) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) ![Issues](https://img.shields.io/github/issues/ekscrypto/SwiftPublicSuffixList) ![Releases](https://img.shields.io/github/v/release/ekscrypto/SwiftPublicSuffixList)

# SwiftPublicSuffixList

This library is a Swift implementation of the necessary code to check a domain name against the [Public Suffix List](https://publicsuffix.org) list and identify if the domains should be restricted.

Restricted domains should not be allowed to set cookies, directly host websites or send/receive emails.

As of January 2022, the list contained over 9k entries.

## Performance Considerations
Due to the high number of entries in the Public Suffix list (>9k), you may want to pre-load on a background thread the
PublicSuffixRulesRegistry.rules soon after launching the app.  Initial loading of the list may require between 100ms to 900ms depending on the host device.

## Regular Updates Recommended
* The [Public Suffix List](https://publicsuffix.org) is updated regularly, if your application is published regularly you may be fine by simply pulling the latest version of the SwiftPublicSuffixList library.  However it is recommended to have
your application retrieve the latest copy of the public suffix list on a somewhat regular basis.

LAST UPDATED: 2022-01-29 15:30:00 EST

### Shell Command
You can run the Utilities/update-suffix.swift from the command line to download & process the text file containing the Public Suffix List and re-generate the PublicSuffixRulesRegistry.swift file.

    # swift update-suffix.swift

### From Swift at runtime:
TODO!

## Classes & Usage

### PublicSuffixList

#### .match(_ candidate: String, rules: [[String]]) -> Match?

    import SwiftPublicSuffixList
    
Using the default built-in Public Suffix List rules

    if let match = PublicSuffixList.match("yahoo.com") {
        // match.isRestricted == false
    }

Using a single custom validation rule, requiring domains to
end with .com but allow any domain within the .com TLD

    if let match = PublicSuffixList.match("yahoo.com", rules: [["com"]]) {
        // match.isRestricted == false
        // match.prevailingRule == ["com"]
        // match.matchedRules == [["com"]]
    }

Using a single custom validation rule, restriction domains that
end with .com but allowing any subdomain    

    if let match = PublicSuffixList.match("yahoo.com", rules: [["*","com"]]) {
       // yahoo.com matches \*.com and so it is restricted
       // match.isRestricted == true
       // match.prevailingRule == ["*","com"]
       // match.matchedRules == [["*","com"]]
    }

    if let match = PublicSuffixList.match("www.yahoo.com", [["*","com"]]) {
       // While yahoo.co matches \*.com and is restricted, there are no
       // restrictions for subdomains such as www.yahoo.com
       // match.isRestricted == false
       // match.prevailingRule == ["*","com"]
       // match.matchedRules == [["*","com"]]
    }

Defining an exception to a more generic rule

    if let match = PublicSuffixList.match("yahoo.com", rules: [["*","com"],["!yahoo","com"]]) {
        // Even if yahoo.com matches *.com, since there is an exception
        // for this domain (defined using !) it will not be restricted
        // match.isRestricted == false
        // match.prevailingRule == ["!yahoo","com"]
        // match.matchedRules == [["*","com"],["!yahoo","com"]]
    }

#### .isUnrestricted(_ candiate: String, rules: [[String]]) -> Bool

Convenience function that will attempt to retrieve a match then return the value of !match.isRestricted.  Will return false if no match was found.

    if PublicSuffixList.isUnrestricted("yahoo.com") {
        // true! yahoo.com is unrestricted by default
    }

