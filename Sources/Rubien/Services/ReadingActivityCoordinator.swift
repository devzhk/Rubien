#if os(macOS)
import AppKit
import Combine
import Foundation
import RubienCore

extension Notification.Name {
    static let rubienActivityDidChange = Notification.Name("Rubien.activityDidChange")
}

private let readingActivityLog = RubienLogger(
    subsystem: "Rubien",
    category: "ReadingActivity"
)

/// Serial, off-main-actor accumulator for estimated foreground reader time.
/// It stores cumulative daily components rather than raw start/stop events.
actor ReadingActivityCoordinator {
    static let shared = ReadingActivityCoordinator()

    private struct ActiveReader {
        let referenceId: Int64
        let db: AppDatabase
        var localDay: LocalDay
        var context: ActivityCaptureContext
        var persistedSeconds: Int64
        var addedSeconds: Double
        var lastTick: ContinuousClock.Instant
        var lastActiveAt: Date

        var cumulativeSeconds: Int64 {
            persistedSeconds + Int64(addedSeconds.rounded(.down))
        }
    }

    private let clock = ContinuousClock()
    private var active: ActiveReader?
    private var latestSequence: UInt64 = 0

    /// Called by the main-actor window monitor on lifecycle changes and once
    /// per second while the app runs. Sequence numbers make independently
    /// scheduled Tasks deterministic when focus changes rapidly.
    func setActiveReader(
        referenceId: Int64?,
        database: AppDatabase?,
        wallDate: Date,
        sequence: UInt64,
        monotonicTick: ContinuousClock.Instant? = nil
    ) {
        guard sequence >= latestSequence else { return }
        latestSequence = sequence
        let nowTick = monotonicTick ?? clock.now

        if var current = active {
            accrue(&current, through: nowTick, wallDate: wallDate)
            let newDay = LocalDay(
                date: wallDate,
                calendar: AppDatabase.activityCalendar()
            )
            let remainsActive = referenceId == current.referenceId && database != nil

            if remainsActive, newDay == current.localDay {
                guard reconcileCaptureContext(&current) else {
                    active = nil
                    if let referenceId, let database {
                        start(
                            referenceId: referenceId,
                            database: database,
                            wallDate: wallDate,
                            tick: nowTick
                        )
                    }
                    return
                }
                guard flushIfNeeded(&current) else {
                    active = nil
                    if let referenceId, let database {
                        start(
                            referenceId: referenceId,
                            database: database,
                            wallDate: wallDate,
                            tick: nowTick
                        )
                    }
                    return
                }
                active = current
                return
            }

            _ = flush(&current)
            active = nil
        }

        guard let referenceId, let database else { return }
        start(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate,
            tick: nowTick
        )
    }

    /// Establish a hard reset boundary while serialized with every pending
    /// timer/focus update. Pre-clear in-memory seconds are deliberately
    /// discarded, the database epoch is advanced, and an eligible reader is
    /// restarted immediately under the new epoch.
    func clearReadingActivity(
        in database: AppDatabase,
        restartReferenceId: Int64?,
        restartDatabase: AppDatabase?,
        wallDate: Date,
        sequence: UInt64,
        monotonicTick: ContinuousClock.Instant? = nil
    ) throws {
        latestSequence = max(latestSequence, sequence)
        let nowTick = monotonicTick ?? clock.now

        var paused = active
        if var reader = paused {
            accrue(&reader, through: nowTick, wallDate: wallDate)
            paused = reader
        }
        active = nil

        do {
            try database.clearActivity(kind: .reading, now: wallDate)
        } catch {
            // A failed clear must not silently lose the accumulator it was
            // attempting to supersede.
            active = paused
            throw error
        }

        if let restartReferenceId, let restartDatabase {
            start(
                referenceId: restartReferenceId,
                database: restartDatabase,
                wallDate: wallDate,
                tick: nowTick
            )
        }
    }

    private func start(
        referenceId: Int64,
        database: AppDatabase,
        wallDate: Date,
        tick: ContinuousClock.Instant
    ) {
        do {
            let day = LocalDay(
                date: wallDate,
                calendar: AppDatabase.activityCalendar()
            )
            let context = try database.activityCaptureContext(for: .reading)
            let stored = try database.readingActivityComponent(
                installationId: RubienPreferences.activityInstallationId,
                referenceId: referenceId,
                localDay: day,
                context: context
            )
            active = ActiveReader(
                referenceId: referenceId,
                db: database,
                localDay: day,
                context: context,
                persistedSeconds: stored?.activeSeconds ?? 0,
                addedSeconds: 0,
                lastTick: tick,
                lastActiveAt: wallDate
            )
        } catch {
            readingActivityLog.error(
                "Could not start activity capture for reference \(referenceId): \(error.localizedDescription)"
            )
        }
    }

    private func accrue(
        _ reader: inout ActiveReader,
        through tick: ContinuousClock.Instant,
        wallDate: Date
    ) {
        let elapsed = reader.lastTick.duration(to: tick).components
        let seconds = Double(elapsed.seconds)
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
        if seconds > 0 {
            // Eligibility is owned by the explicit window, application, and
            // sleep lifecycle signals in ReadingActivityWindowMonitor. A busy
            // main run loop may delay the one-second timer, but that does not
            // make the still-key foreground reader inactive, so retain the
            // full monotonic interval instead of dropping it heuristically.
            reader.addedSeconds += seconds
            reader.lastActiveAt = wallDate
        }
        reader.lastTick = tick
    }

    /// Reconcile a still-eligible reader with the current reset epoch.
    /// Ordinary library-change broadcasts leave the accumulator untouched.
    /// A rebase of the same pending clear carries its post-clear cumulative
    /// value forward; a distinct clear discards the old epoch and asks the
    /// caller to restart immediately.
    private func reconcileCaptureContext(_ reader: inout ActiveReader) -> Bool {
        let current: ActivityCaptureContext
        do {
            current = try reader.db.activityCaptureContext(for: .reading)
        } catch {
            readingActivityLog.error(
                "Could not refresh reading activity epoch: \(error.localizedDescription)"
            )
            return true
        }

        if current == reader.context { return true }

        let sameEpoch = current.revision == reader.context.revision
            && current.generation == reader.context.generation
        if sameEpoch {
            // Cloud acknowledgement only removes the pending-intent marker;
            // it does not create a new logical reset boundary.
            reader.context = current
            return true
        }

        if let intent = reader.context.pendingClearIntentId,
           intent == current.pendingClearIntentId
        {
            // The same user clear was rebased after a sync conflict. Force a
            // write even when the usual one-minute cadence has not elapsed so
            // its post-clear delta moves to the rebased generation before the
            // pending intent can be acknowledged.
            reader.context = current
            return flush(&reader, force: true)
        }

        return false
    }

    private func flushIfNeeded(_ reader: inout ActiveReader) -> Bool {
        let cumulative = reader.cumulativeSeconds
        let crossedQualification = reader.persistedSeconds < 60 && cumulative >= 60
        let reachedMinuteCadence = cumulative - reader.persistedSeconds >= 60
        if crossedQualification || reachedMinuteCadence {
            return flush(&reader)
        }
        return true
    }

    private func flush(
        _ reader: inout ActiveReader,
        force: Bool = false
    ) -> Bool {
        let cumulative = reader.cumulativeSeconds
        guard cumulative > reader.persistedSeconds || (force && cumulative > 0) else {
            return true
        }
        let referenceId = reader.referenceId
        let fractionalSeconds = reader.addedSeconds - reader.addedSeconds.rounded(.down)
        do {
            let disposition = try reader.db.saveReadingActivityCounter(
                installationId: RubienPreferences.activityInstallationId,
                referenceId: reader.referenceId,
                localDay: reader.localDay,
                cumulativeActiveSeconds: cumulative,
                lastActiveAt: reader.lastActiveAt,
                context: reader.context
            )
            switch disposition {
            case .saved(let saved):
                reader.persistedSeconds = saved.activeSeconds
                reader.addedSeconds = max(0, fractionalSeconds)
                reader.context = ActivityCaptureContext(
                    kind: .reading,
                    revision: saved.epochRevision,
                    generation: saved.generation,
                    pendingClearIntentId: reader.context.pendingClearIntentId
                )
                Task { @MainActor in
                    NotificationCenter.default.post(name: .rubienActivityDidChange, object: nil)
                }
                return true
            case .staleEpoch:
                // A distinct clear superseded this accumulator. Discard its
                // pre-clear seconds; the next monitor tick starts a fresh one.
                return false
            }
        } catch {
            // Keep the in-memory delta for the next tick/pause retry. A crash
            // can still lose at most the unflushed interval.
            readingActivityLog.error(
                "Activity flush failed for reference \(referenceId): \(error.localizedDescription)"
            )
            return true
        }
    }
}

/// Main-actor bridge from AppKit window/application lifecycle into the actor
/// above. It deliberately observes the actual reader NSWindows: previews,
/// Quick Look, CLI/MCP reads, and Assistant tool reads never register here.
@MainActor
final class ReadingActivityWindowMonitor {
    static let shared = ReadingActivityWindowMonitor()

    private struct Registration {
        weak var window: NSWindow?
        let referenceId: Int64
        let database: AppDatabase
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var observers: [NSObjectProtocol] = []
    private var libraryChangeCancellable: AnyCancellable?
    private var timer: Timer?
    private var isSystemAwake = true
    private var sequence: UInt64 = 0

    private init() {
        let center = NotificationCenter.default
        let lifecycleNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]
        for name in lifecycleNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSystemAwake = false
                self?.refresh()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSystemAwake = true
                self?.refresh()
            }
        })
        observers.append(center.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceBoundary() }
        })

        libraryChangeCancellable = LibraryChangeBroadcaster.shared.events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    func register(window: NSWindow, referenceId: Int64, database: AppDatabase) {
        registrations[ObjectIdentifier(window)] = Registration(
            window: window,
            referenceId: referenceId,
            database: database
        )
        startTimerIfNeeded()
        refresh()
    }

    func unregister(window: NSWindow) {
        registrations.removeValue(forKey: ObjectIdentifier(window))
        refresh()
    }

    func refresh() {
        registrations = registrations.filter { $0.value.window != nil }
        stopTimerIfIdle()
        let selected = eligibleRegistration()

        sequence &+= 1
        let currentSequence = sequence
        Task {
            await ReadingActivityCoordinator.shared.setActiveReader(
                referenceId: selected?.referenceId,
                database: selected?.database,
                wallDate: Date(),
                sequence: currentSequence
            )
        }
    }

    /// Run an in-app reading reset through the accumulator actor so the clear
    /// cannot race a queued timer tick. The selected reader is restarted before
    /// this method returns; the final refresh catches any focus change that
    /// occurred while the database write was in flight.
    func clearReadingActivity(in database: AppDatabase) async throws {
        registrations = registrations.filter { $0.value.window != nil }
        stopTimerIfIdle()
        let selected = eligibleRegistration()
        sequence &+= 1
        try await ReadingActivityCoordinator.shared.clearReadingActivity(
            in: database,
            restartReferenceId: selected?.referenceId,
            restartDatabase: selected?.database,
            wallDate: Date(),
            sequence: sequence
        )
        refresh()
    }

    var isPollingForActivity: Bool { timer != nil }

    private func eligibleRegistration() -> Registration? {
        guard isSystemAwake,
              NSApp.isActive,
              RubienPreferences.recordReadingActivity
        else { return nil }
        return registrations.values.first {
            guard let window = $0.window else { return false }
            return window.isKeyWindow && window.isVisible && !window.isMiniaturized
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !registrations.isEmpty else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimerIfIdle() {
        guard registrations.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    private func forceBoundary() {
        sequence &+= 1
        let pauseSequence = sequence
        Task {
            await ReadingActivityCoordinator.shared.setActiveReader(
                referenceId: nil,
                database: nil,
                wallDate: Date(),
                sequence: pauseSequence
            )
        }
        refresh()
    }
}
#endif
