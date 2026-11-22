import Foundation

/// Decodes HTML character references in metadata text: `citation_*` meta values,
/// Crossref JATS abstracts, eLife fragments and Cell Press titles. Pure Swift, so
/// RubienCore keeps building on Linux (no `NSAttributedString` HTML import).
enum HTMLEntities {
    /// Decodes decimal (`&#233;`) and hexadecimal (`&#xE9;`) references and the HTML 4
    /// named references plus `&apos;` (`&eacute;`, `&nbsp;`, `&mdash;`), each closed by
    /// `;`. Names are case-sensitive. Unknown names and malformed references stay
    /// literal; numeric references to invalid code points become U+FFFD, as in browsers.
    ///
    /// Some publishers escape values twice (`St&amp;#233;fan`), so an escaped `&` that
    /// is directly followed by another reference decodes that reference as well. The
    /// previous decoder already did this for `&amp;quot;`, `&amp;lt;` and similar.
    static func decode(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        // Scan scalars, not Characters: a combining mark after `;` would otherwise
        // merge with it into one Character and hide the terminator.
        let scalars = Array(text.unicodeScalars)
        var decoded = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&",
                  var match = reference(in: scalars, from: index + 1) else {
                decoded.append(scalars[index])
                index += 1
                continue
            }
            if match.scalar == "&", let inner = reference(in: scalars, from: match.end) {
                match = inner
            }
            decoded.append(match.scalar)
            index = match.end
        }
        return String(decoded)
    }

    /// Parses the reference that starts at `start`, just after its `&`. Returns the
    /// decoded scalar and the index after the closing `;`.
    private static func reference(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> (scalar: Unicode.Scalar, end: Int)? {
        var index = start
        let codePoint: UInt32
        if index < scalars.count, scalars[index] == "#" {
            index += 1
            var radix: UInt32 = 10
            if index < scalars.count, scalars[index] == "x" || scalars[index] == "X" {
                radix = 16
                index += 1
            }
            let digitsStart = index
            var value: UInt32 = 0
            while index < scalars.count, let digit = digitValue(scalars[index]), digit < radix {
                // Saturate: every value past U+10FFFF is equally invalid.
                value = min(value * radix + digit, 0x110000)
                index += 1
            }
            guard index > digitsStart else { return nil }
            codePoint = value
        } else {
            let nameStart = index
            while index < scalars.count, index - nameStart < longestName,
                  isASCIIAlphanumeric(scalars[index]) {
                index += 1
            }
            var name = ""
            name.unicodeScalars.append(contentsOf: scalars[nameStart..<index])
            guard let value = namedReferences[name] else { return nil }
            codePoint = value
        }
        guard index < scalars.count, scalars[index] == ";" else { return nil }
        return (scalar(forCodePoint: codePoint), index + 1)
    }

    /// HTML's numeric-reference rules: 0x80–0x9F name their Windows-1252 characters
    /// (legacy pages write `&#146;` for ’); NUL, surrogates and values past U+10FFFF
    /// become U+FFFD.
    private static func scalar(forCodePoint codePoint: UInt32) -> Unicode.Scalar {
        if (0x80...0x9F).contains(codePoint),
           let mapped = Unicode.Scalar(windows1252[Int(codePoint - 0x80)]) {
            return mapped
        }
        guard codePoint != 0, let scalar = Unicode.Scalar(codePoint) else { return "\u{FFFD}" }
        return scalar
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - 0x30
        case "a"..."f": return scalar.value - 0x61 + 10
        case "A"..."F": return scalar.value - 0x41 + 10
        default: return nil
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."z", "A"..."Z": return true
        default: return false
        }
    }

    private static let longestName = namedReferences.keys.map(\.count).max() ?? 0

    /// The HTML 4.01 named references plus `&apos;`, at the code points HTML5 (and so
    /// every browser) assigns them; HTML5 moved `lang`/`rang` to U+27E8/U+27E9.
    private static let namedReferences: [String: UInt32] = [
        "quot": 0x0022, "amp": 0x0026, "apos": 0x0027, "lt": 0x003C, "gt": 0x003E, "nbsp": 0x00A0,
        "iexcl": 0x00A1, "cent": 0x00A2, "pound": 0x00A3, "curren": 0x00A4, "yen": 0x00A5,
        "brvbar": 0x00A6, "sect": 0x00A7, "uml": 0x00A8, "copy": 0x00A9, "ordf": 0x00AA, "laquo": 0x00AB,
        "not": 0x00AC, "shy": 0x00AD, "reg": 0x00AE, "macr": 0x00AF, "deg": 0x00B0, "plusmn": 0x00B1,
        "sup2": 0x00B2, "sup3": 0x00B3, "acute": 0x00B4, "micro": 0x00B5, "para": 0x00B6, "middot": 0x00B7,
        "cedil": 0x00B8, "sup1": 0x00B9, "ordm": 0x00BA, "raquo": 0x00BB, "frac14": 0x00BC,
        "frac12": 0x00BD, "frac34": 0x00BE, "iquest": 0x00BF, "Agrave": 0x00C0, "Aacute": 0x00C1,
        "Acirc": 0x00C2, "Atilde": 0x00C3, "Auml": 0x00C4, "Aring": 0x00C5, "AElig": 0x00C6,
        "Ccedil": 0x00C7, "Egrave": 0x00C8, "Eacute": 0x00C9, "Ecirc": 0x00CA, "Euml": 0x00CB,
        "Igrave": 0x00CC, "Iacute": 0x00CD, "Icirc": 0x00CE, "Iuml": 0x00CF, "ETH": 0x00D0,
        "Ntilde": 0x00D1, "Ograve": 0x00D2, "Oacute": 0x00D3, "Ocirc": 0x00D4, "Otilde": 0x00D5,
        "Ouml": 0x00D6, "times": 0x00D7, "Oslash": 0x00D8, "Ugrave": 0x00D9, "Uacute": 0x00DA,
        "Ucirc": 0x00DB, "Uuml": 0x00DC, "Yacute": 0x00DD, "THORN": 0x00DE, "szlig": 0x00DF,
        "agrave": 0x00E0, "aacute": 0x00E1, "acirc": 0x00E2, "atilde": 0x00E3, "auml": 0x00E4,
        "aring": 0x00E5, "aelig": 0x00E6, "ccedil": 0x00E7, "egrave": 0x00E8, "eacute": 0x00E9,
        "ecirc": 0x00EA, "euml": 0x00EB, "igrave": 0x00EC, "iacute": 0x00ED, "icirc": 0x00EE,
        "iuml": 0x00EF, "eth": 0x00F0, "ntilde": 0x00F1, "ograve": 0x00F2, "oacute": 0x00F3,
        "ocirc": 0x00F4, "otilde": 0x00F5, "ouml": 0x00F6, "divide": 0x00F7, "oslash": 0x00F8,
        "ugrave": 0x00F9, "uacute": 0x00FA, "ucirc": 0x00FB, "uuml": 0x00FC, "yacute": 0x00FD,
        "thorn": 0x00FE, "yuml": 0x00FF, "OElig": 0x0152, "oelig": 0x0153, "Scaron": 0x0160,
        "scaron": 0x0161, "Yuml": 0x0178, "fnof": 0x0192, "circ": 0x02C6, "tilde": 0x02DC, "Alpha": 0x0391,
        "Beta": 0x0392, "Gamma": 0x0393, "Delta": 0x0394, "Epsilon": 0x0395, "Zeta": 0x0396, "Eta": 0x0397,
        "Theta": 0x0398, "Iota": 0x0399, "Kappa": 0x039A, "Lambda": 0x039B, "Mu": 0x039C, "Nu": 0x039D,
        "Xi": 0x039E, "Omicron": 0x039F, "Pi": 0x03A0, "Rho": 0x03A1, "Sigma": 0x03A3, "Tau": 0x03A4,
        "Upsilon": 0x03A5, "Phi": 0x03A6, "Chi": 0x03A7, "Psi": 0x03A8, "Omega": 0x03A9, "alpha": 0x03B1,
        "beta": 0x03B2, "gamma": 0x03B3, "delta": 0x03B4, "epsilon": 0x03B5, "zeta": 0x03B6, "eta": 0x03B7,
        "theta": 0x03B8, "iota": 0x03B9, "kappa": 0x03BA, "lambda": 0x03BB, "mu": 0x03BC, "nu": 0x03BD,
        "xi": 0x03BE, "omicron": 0x03BF, "pi": 0x03C0, "rho": 0x03C1, "sigmaf": 0x03C2, "sigma": 0x03C3,
        "tau": 0x03C4, "upsilon": 0x03C5, "phi": 0x03C6, "chi": 0x03C7, "psi": 0x03C8, "omega": 0x03C9,
        "thetasym": 0x03D1, "upsih": 0x03D2, "piv": 0x03D6, "ensp": 0x2002, "emsp": 0x2003,
        "thinsp": 0x2009, "zwnj": 0x200C, "zwj": 0x200D, "lrm": 0x200E, "rlm": 0x200F, "ndash": 0x2013,
        "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C,
        "rdquo": 0x201D, "bdquo": 0x201E, "dagger": 0x2020, "Dagger": 0x2021, "bull": 0x2022,
        "hellip": 0x2026, "permil": 0x2030, "prime": 0x2032, "Prime": 0x2033, "lsaquo": 0x2039,
        "rsaquo": 0x203A, "oline": 0x203E, "frasl": 0x2044, "euro": 0x20AC, "image": 0x2111,
        "weierp": 0x2118, "real": 0x211C, "trade": 0x2122, "alefsym": 0x2135, "larr": 0x2190,
        "uarr": 0x2191, "rarr": 0x2192, "darr": 0x2193, "harr": 0x2194, "crarr": 0x21B5, "lArr": 0x21D0,
        "uArr": 0x21D1, "rArr": 0x21D2, "dArr": 0x21D3, "hArr": 0x21D4, "forall": 0x2200, "part": 0x2202,
        "exist": 0x2203, "empty": 0x2205, "nabla": 0x2207, "isin": 0x2208, "notin": 0x2209, "ni": 0x220B,
        "prod": 0x220F, "sum": 0x2211, "minus": 0x2212, "lowast": 0x2217, "radic": 0x221A, "prop": 0x221D,
        "infin": 0x221E, "ang": 0x2220, "and": 0x2227, "or": 0x2228, "cap": 0x2229, "cup": 0x222A,
        "int": 0x222B, "there4": 0x2234, "sim": 0x223C, "cong": 0x2245, "asymp": 0x2248, "ne": 0x2260,
        "equiv": 0x2261, "le": 0x2264, "ge": 0x2265, "sub": 0x2282, "sup": 0x2283, "nsub": 0x2284,
        "sube": 0x2286, "supe": 0x2287, "oplus": 0x2295, "otimes": 0x2297, "perp": 0x22A5, "sdot": 0x22C5,
        "lceil": 0x2308, "rceil": 0x2309, "lfloor": 0x230A, "rfloor": 0x230B, "loz": 0x25CA,
        "spades": 0x2660, "clubs": 0x2663, "hearts": 0x2665, "diams": 0x2666, "lang": 0x27E8,
        "rang": 0x27E9,
    ]

    /// Windows-1252 characters for numeric references 0x80–0x9F, per the HTML spec.
    /// The five bytes Windows-1252 leaves undefined keep their own code point.
    private static let windows1252: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]
}
