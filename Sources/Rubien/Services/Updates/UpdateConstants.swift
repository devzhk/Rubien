#if Sparkle
import Foundation

enum UpdateConstants {
    /// GitHub Pages-served appcast for production releases.
    static let productionFeedURL = URL(string: "https://devzhk.github.io/Rubien/appcast.xml")!

    /// Sibling appcast for end-to-end staging tests; activated by the
    /// STAGING_FEED=1 environment variable or the equivalent Info.plist
    /// override in debug builds.
    static let stagingFeedURL = URL(string: "https://devzhk.github.io/Rubien/staging-appcast.xml")!

    /// Background check cadence; matches the SUScheduledCheckInterval
    /// stamped into Info.plist at build time.
    static let scheduledCheckInterval: TimeInterval = 86_400
}
#endif
