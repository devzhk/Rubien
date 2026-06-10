#if os(macOS)
import AppKit

/// Strict hex color helpers for the accent-color preference path.
///
/// Deliberately separate from the lenient, memoized `Color(hex:)` used by tag
/// chips (SidebarView.swift): that parser maps garbage to near-black, which is
/// fine for chips but would silently pin the app accent to black on a corrupt
/// stored value. Here, anything that isn't exactly "#RRGGBB"/"RRGGBB" is nil.
enum ColorHex {
    /// Strict "#RRGGBB"/"RRGGBB" parse; nil unless exactly 6 hex digits.
    /// Strips at most ONE leading "#" — trimming a character set would
    /// wrongly accept "##3379D8" or "3379D8#".
    static func components(from hex: String) -> (r: Double, g: Double, b: Double)? {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6, body.allSatisfy(\.isHexDigit),
              let int = UInt64(body, radix: 16) else { return nil }
        return (Double((int >> 16) & 0xFF) / 255,
                Double((int >> 8) & 0xFF) / 255,
                Double(int & 0xFF) / 255)
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB. `usingColorSpace(.sRGB)` is mandatory: catalog and
    /// dynamic colors (e.g. `controlAccentColor`) raise on direct component
    /// access, and it also normalizes picks from other color spaces (P3).
    var srgbHexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((srgb.redComponent * 255).rounded()),
                      Int((srgb.greenComponent * 255).rounded()),
                      Int((srgb.blueComponent * 255).rounded()))
    }

    /// (hue, saturation, brightness), each 0…1, in sRGB — the inverse of the
    /// `Color(hue:saturation:brightness:)` the accent wheel commits. Same
    /// mandatory `usingColorSpace(.sRGB)` guard as `srgbHexString`.
    var srgbHSB: (h: Double, s: Double, b: Double)? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return (Double(h), Double(s), Double(b))
    }
}
#endif
