import Foundation

enum RubienDebugLogging {
    private static let environment = ProcessInfo.processInfo.environment

    static let metadataVerbose = environment["SWIFTLIB_DEBUG_METADATA"] == "1"
    static let runtimeVerbose = metadataVerbose || environment["SWIFTLIB_DEBUG_RUNTIME"] == "1"
}
