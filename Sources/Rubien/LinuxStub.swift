#if !os(macOS)
// `Rubien` is the macOS-only SwiftUI app. The target is declared in the
// manifest for cross-platform builds (and `swift test` builds the whole
// package), but every real source file is gated `#if os(macOS)` and
// compiles to empty on Linux. This stub gives the executable a `@main`
// so the link step succeeds; the binary is never invoked on Linux.
@main
enum RubienLinuxStub {
    static func main() {
        fatalError("Rubien GUI is macOS-only")
    }
}
#endif
