#if canImport(Sparkle)
import Foundation
import Combine
import Sparkle

/// Narrow abstraction over `SPUUpdater` used by `UpdateController` so unit
/// tests can drive the controller with a fake without spinning up real
/// Sparkle XPC services. Only the surface the controller actually reads
/// is exposed; the controller never imports Sparkle directly through this
/// protocol so substitution at test time is straightforward.
@MainActor
protocol UpdaterProtocol: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    var stateChanges: AnyPublisher<Void, Never> { get }

    func checkForUpdates()
    func checkForUpdatesInBackground()
}

extension SPUUpdater: UpdaterProtocol {
    var stateChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            publisher(for: \.canCheckForUpdates, options: [.new]).map { _ in () }.eraseToAnyPublisher(),
            publisher(for: \.sessionInProgress, options: [.new]).map { _ in () }.eraseToAnyPublisher(),
            publisher(for: \.lastUpdateCheckDate, options: [.new]).map { _ in () }.eraseToAnyPublisher(),
            publisher(for: \.automaticallyChecksForUpdates, options: [.new]).map { _ in () }.eraseToAnyPublisher(),
        ]).eraseToAnyPublisher()
    }
}
#endif
