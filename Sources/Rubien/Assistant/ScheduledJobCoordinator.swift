#if os(macOS)
import AppKit
import Combine
import Foundation
import RubienCore
import UserNotifications

/// App-lifetime scheduler and observable UI state. macOS timers are advisory:
/// wake/foreground/clock-change hooks always rescan transactionally, so sleep or
/// timer coalescing cannot duplicate or permanently skip an occurrence.
@MainActor
final class ScheduledJobCoordinator: ObservableObject {
    struct BackgroundActivityTiming: Equatable {
        let interval: TimeInterval
        let tolerance: TimeInterval
    }

    @Published private(set) var jobs: [ScheduledJob] = []
    @Published private(set) var upcomingJobs: [ScheduledJob] = []
    @Published private(set) var recentRuns: [ScheduledJobRun] = []
    @Published private(set) var unreadRunCount = 0
    @Published private(set) var activeRun: ScheduledJobRun?
    /// Bounded live output for the active run.
    @Published private(set) var activeRunProgress: ScheduledJobProgress?
    /// Terminal snapshots retained for this app launch, so viewing run A remains
    /// stable when another due job begins immediately afterward.
    @Published private var recentRunProgress: [String: ScheduledJobProgress] = [:]
    /// Result sessions proven missing from the provider during this app launch.
    /// Keeping the refusal in memory prevents Recent Runs from continuing to offer
    /// an Open Result action that has already failed its transcript preflight.
    @Published private(set) var unavailableResultRunIDs: Set<String> = []

    private let database: AppDatabase
    private let runner: ScheduledJobRunner
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let completionNotifier: (ScheduledJob, ScheduledJobRun) -> Void
    private let notificationAuthorizationRequester: () -> Void
    private let usesBackgroundScheduler: Bool
    private let logger = RubienLogger(
        subsystem: "com.rubien.assistant",
        category: "ScheduledJobCoordinator"
    )
    private var timer: Timer?
    private var backgroundActivity: NSBackgroundActivityScheduler?
    private var dueRetryNotBefore: Date?
    private var executionTask: Task<Void, Never>?
    private var progressAccumulator: ScheduledJobProgress?
    private var pendingProgressAssistantDelta = ""
    private var progressPublishTask: Task<Void, Never>?
    private var recentRunProgressOrder: [String] = []
    private var started = false
    private static let maximumRetainedProgressRuns = 8
    private var didRequestNotificationAuthorization = false
    private var observers: [NSObjectProtocol] = []
    private var libraryChangeCancellable: AnyCancellable?

    convenience init(database: AppDatabase = .shared) {
        let contentChannel = MCPContentChannel.resolveBundled()
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { kind in
                AssistantProviderFactory.make(
                    kind,
                    contentChannel: contentChannel,
                    // Scheduled Codex must use the same process-wide connection as
                    // Home/readers. Its read-only spawn posture is applied only after
                    // an active interactive turn has ended and reaped.
                    shareCodexAppServer: true)
            },
            workspaceProvider: { RubienPreferences.assistantWorkspaceURL },
            contentChannelAvailable: contentChannel != nil
        )
        self.init(
            database: database,
            runner: runner,
            completionNotifier: ScheduledJobNotifications.post
        )
    }

    init(
        database: AppDatabase,
        runner: ScheduledJobRunner,
        now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        completionNotifier: @escaping (ScheduledJob, ScheduledJobRun) -> Void = { _, _ in },
        notificationAuthorizationRequester: @escaping () -> Void = {
            ScheduledJobNotifications.requestAuthorization()
        },
        usesBackgroundScheduler: Bool = true
    ) {
        self.database = database
        self.runner = runner
        self.now = now
        self.calendar = calendar
        self.completionNotifier = completionNotifier
        self.notificationAuthorizationRequester = notificationAuthorizationRequester
        self.usesBackgroundScheduler = usesBackgroundScheduler
    }

    var isRunning: Bool { activeRun != nil }

    func job(id: String) -> ScheduledJob? {
        jobs.first { $0.id == id }
    }

    func progress(for runID: String) -> ScheduledJobProgress? {
        if activeRunProgress?.runID == runID { return activeRunProgress }
        return recentRunProgress[runID]
    }

    func start() {
        guard !started else { return }
        started = true
        installObservers()
        do {
            _ = try database.recoverInterruptedScheduledJobRuns(at: now())
            try database.recalculateScheduledJobNextRuns(now: now(), calendar: calendar())
            refresh()
            requestNotificationAuthorizationIfNeeded()
            scanForDueJobs()
        } catch {
            logger.error("startup reconciliation failed: \(error.localizedDescription)")
            refresh()
        }
    }

    func refresh() {
        do {
            let snapshot = try database.fetchScheduledJobDashboard()
            if jobs != snapshot.jobs { jobs = snapshot.jobs }
            if upcomingJobs != snapshot.upcomingJobs { upcomingJobs = snapshot.upcomingJobs }
            if recentRuns != snapshot.recentRuns { recentRuns = snapshot.recentRuns }
            if unreadRunCount != snapshot.unreadRunCount {
                unreadRunCount = snapshot.unreadRunCount
            }
            scheduleTimer()
        } catch {
            logger.error("dashboard refresh failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func create(_ definition: ScheduledJobDefinition) throws -> ScheduledJob {
        let job = try database.createScheduledJob(
            definition,
            now: now(),
            calendar: calendar()
        )
        didMutate()
        return job
    }

    @discardableResult
    func update(id: String, definition: ScheduledJobDefinition) throws -> ScheduledJob {
        let job = try database.updateScheduledJob(
            id: id,
            definition: definition,
            now: now(),
            calendar: calendar()
        )
        didMutate()
        return job
    }

    @discardableResult
    func setEnabled(id: String, isEnabled: Bool) throws -> ScheduledJob {
        let job = try database.setScheduledJobEnabled(
            id: id,
            isEnabled: isEnabled,
            now: now(),
            calendar: calendar()
        )
        didMutate()
        return job
    }

    func delete(id: String) throws {
        try database.deleteScheduledJob(id: id)
        didMutate()
    }

    func runNow(id: String) throws {
        guard executionTask == nil else { throw ScheduledJobError.runnerBusy }
        let claim = try database.claimManualScheduledJob(id: id, now: now())
        beginExecution(with: claim)
    }

    func cancelActiveRun() {
        guard let runID = activeRun?.id else { return }
        cancelActiveRun(id: runID)
    }

    /// Cancel only if the run that rendered the action is still active. A queued
    /// successor may start between SwiftUI drawing a button and the click arriving;
    /// an unscoped cancellation would terminate that different run.
    func cancelActiveRun(id: String) {
        guard activeRun?.id == id else { return }
        runner.cancel(runID: id)
    }

    func markRunRead(id: String) {
        try? database.markScheduledJobRunRead(id: id)
        refresh()
    }

    func markAllRunsRead() {
        try? database.markAllScheduledJobRunsRead()
        refresh()
    }

    func deleteRun(id: String) throws {
        try database.deleteScheduledJobRun(id: id, at: now())
        unavailableResultRunIDs.remove(id)
        recentRunProgress[id] = nil
        recentRunProgressOrder.removeAll { $0 == id }
        if activeRun == nil, activeRunProgress?.runID == id {
            progressPublishTask?.cancel()
            progressPublishTask = nil
            pendingProgressAssistantDelta = ""
            progressAccumulator = nil
            activeRunProgress = nil
        }
        refresh()
    }

    func markResultUnavailable(id: String) {
        unavailableResultRunIDs.insert(id)
    }

    private func didMutate(resetDueRetry: Bool = true) {
        if resetDueRetry { dueRetryNotBefore = nil }
        refresh()
        requestNotificationAuthorizationIfNeeded()
        scanForDueJobs()
    }

    private func scanForDueJobs() {
        guard started, executionTask == nil else { return }
        if let dueRetryNotBefore, dueRetryNotBefore > now() {
            refresh()
            return
        }
        do {
            guard let claim = try database.claimNextDueScheduledJob(
                now: now(),
                calendar: calendar()
            ) else {
                dueRetryNotBefore = now().addingTimeInterval(5)
                refresh()
                return
            }
            dueRetryNotBefore = nil
            beginExecution(with: claim)
        } catch {
            dueRetryNotBefore = now().addingTimeInterval(5)
            logger.error("due-job claim failed: \(error.localizedDescription)")
            refresh()
        }
    }

    private func beginExecution(with initialClaim: ScheduledJobExecutionClaim) {
        timer?.invalidate()
        timer = nil
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        activeRun = initialClaim.run
        resetProgress(for: initialClaim.run, prompt: initialClaim.job.prompt)
        executionTask = Task { [weak self] in
            guard let self else { return }
            var claim: ScheduledJobExecutionClaim? = initialClaim
            while let currentClaim = claim, !Task.isCancelled {
                self.activeRun = currentClaim.run
                if self.progressAccumulator?.runID != currentClaim.run.id {
                    self.resetProgress(for: currentClaim.run, prompt: currentClaim.job.prompt)
                }
                self.refresh()
                let finishedRun = await self.runner.execute(
                    currentClaim,
                    onStarted: { [weak self] in
                        guard let self else { return }
                        self.activeRun = try? self.database.fetchScheduledJobRun(
                            id: currentClaim.run.id
                        )
                        self.markProgressStarted(runID: currentClaim.run.id)
                        self.refresh()
                    },
                    onEvent: { [weak self] event in
                        self?.recordProgress(event, runID: currentClaim.run.id)
                    }
                )
                if let finishedRun {
                    self.finishProgress(with: finishedRun)
                }
                if let finishedRun, currentClaim.job.notifyOnCompletion {
                    self.completionNotifier(currentClaim.job, finishedRun)
                }
                self.activeRun = nil
                // Publish the just-finished row before claiming a queued successor,
                // so a Home transcript selected by run ID never briefly disappears.
                self.refresh()
                do {
                    claim = try self.database.claimNextDueScheduledJob(
                        now: self.now(),
                        calendar: self.calendar()
                    )
                } catch {
                    self.dueRetryNotBefore = self.now().addingTimeInterval(5)
                    self.logger.error("follow-up claim failed: \(error.localizedDescription)")
                    claim = nil
                }
            }
            self.executionTask = nil
            self.activeRun = nil
            self.refresh()
        }
    }

    private func resetProgress(for run: ScheduledJobRun, prompt: String) {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        pendingProgressAssistantDelta = ""
        let progress = ScheduledJobProgress(run: run, prompt: prompt)
        progressAccumulator = progress
        activeRunProgress = progress
    }

    private func markProgressStarted(runID: String) {
        guard var progress = progressAccumulator, progress.runID == runID else { return }
        progress.markStarted()
        progressAccumulator = progress
        publishProgressNow()
    }

    private func recordProgress(_ event: AgentEvent, runID: String) {
        guard progressAccumulator?.runID == runID else { return }
        if case .assistantDelta(let text) = event {
            pendingProgressAssistantDelta.append(text)
            scheduleProgressPublish()
            return
        }

        flushPendingProgressDelta()
        guard var progress = progressAccumulator else { return }
        progress.record(event)
        progressAccumulator = progress

        if case .turnCompleted = event {
            publishProgressNow()
        } else {
            scheduleProgressPublish()
        }
    }

    private func finishProgress(with run: ScheduledJobRun) {
        guard progressAccumulator?.runID == run.id else { return }
        flushPendingProgressDelta()
        guard var progress = progressAccumulator else { return }
        progress.finish(with: run)
        progressAccumulator = progress
        retainTerminalProgress(progress)
        publishProgressNow()
    }

    private func retainTerminalProgress(_ progress: ScheduledJobProgress) {
        recentRunProgress[progress.runID] = progress
        recentRunProgressOrder.removeAll { $0 == progress.runID }
        recentRunProgressOrder.append(progress.runID)
        while recentRunProgressOrder.count > Self.maximumRetainedProgressRuns {
            recentRunProgress[recentRunProgressOrder.removeFirst()] = nil
        }
    }

    private func flushPendingProgressDelta() {
        guard !pendingProgressAssistantDelta.isEmpty,
              var progress = progressAccumulator
        else { return }
        let delta = pendingProgressAssistantDelta
        pendingProgressAssistantDelta = ""
        progress.record(.assistantDelta(text: delta))
        progressAccumulator = progress
    }

    /// Provider deltas can arrive token-by-token. Coalescing them to four UI
    /// updates per second keeps transcript rendering bounded and leaves the main
    /// actor responsive to Cancel.
    private func scheduleProgressPublish() {
        guard progressPublishTask == nil else { return }
        progressPublishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            self.flushPendingProgressDelta()
            self.activeRunProgress = self.progressAccumulator
            self.progressPublishTask = nil
        }
    }

    private func publishProgressNow() {
        progressPublishTask?.cancel()
        progressPublishTask = nil
        flushPendingProgressDelta()
        activeRunProgress = progressAccumulator
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        guard executionTask == nil,
              activeRun == nil,
              let nextRunAt = upcomingJobs.compactMap(\.nextRunAt).min()
        else { return }
        let deadline = max(nextRunAt, dueRetryNotBefore ?? nextRunAt)
        let delay = deadline.timeIntervalSince(now())
        guard let backgroundTiming = Self.backgroundActivityTiming(for: delay) else {
            // An overdue occurrence is work to claim now, not a future deadline
            // for NSBackgroundActivityScheduler. Defer one actor turn so callers
            // can finish publishing their dashboard snapshot before the claim.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.scanForDueJobs()
            }
            return
        }
        let interval = max(0.1, delay)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.scanForDueJobs() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        guard usesBackgroundScheduler else { return }
        let activity = NSBackgroundActivityScheduler(
            identifier: "com.rubien.scheduled-jobs.next-run"
        )
        activity.repeats = false
        activity.interval = backgroundTiming.interval
        activity.tolerance = backgroundTiming.tolerance
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                self?.scanForDueJobs()
                completion(.finished)
            }
        }
        backgroundActivity = activity
    }

    nonisolated static func backgroundActivityTiming(
        for delay: TimeInterval
    ) -> BackgroundActivityTiming? {
        guard delay.isFinite, delay > 0 else { return nil }
        let interval = max(1, delay)
        return BackgroundActivityTiming(
            interval: interval,
            tolerance: min(60, interval / 2)
        )
    }

    private func reconcileClockAndScan() {
        do {
            try database.recalculateScheduledJobNextRuns(now: now(), calendar: calendar())
        } catch {
            logger.error("clock reconciliation failed: \(error.localizedDescription)")
        }
        refresh()
        scanForDueJobs()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            .NSSystemTimeZoneDidChange,
            .NSSystemClockDidChange,
        ] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // NotificationCenter's `.main` queue guarantees the main
                // thread, but it does not establish Swift's MainActor
                // executor. Hop explicitly instead of trapping in
                // `MainActor.assumeIsolated` during app activation.
                Task { @MainActor [weak self] in
                    if notification.name == .NSSystemTimeZoneDidChange
                        || notification.name == .NSSystemClockDidChange {
                        self?.reconcileClockAndScan()
                    } else {
                        self?.refresh()
                        self?.scanForDueJobs()
                    }
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileClockAndScan() }
        })
        libraryChangeCancellable = LibraryChangeBroadcaster.shared.events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    // The broadcaster covers every CLI/MCP library mutation, not
                    // only schedules, so preserve a genuine claim-failure backoff.
                    self?.didMutate(resetDueRetry: false)
                }
            }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !didRequestNotificationAuthorization,
              jobs.contains(where: { $0.isEnabled && $0.notifyOnCompletion })
        else { return }
        didRequestNotificationAuthorization = true
        notificationAuthorizationRequester()
    }
}

enum ScheduledJobNotifications {
    static let runIDKey = "scheduledJobRunID"
    /// `UNUserNotificationCenter.current()` raises an Objective-C exception for
    /// a raw SwiftPM executable because it has no application bundle proxy.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard isAvailable else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        }
    }

    static func post(job: ScheduledJob, run: ScheduledJobRun) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        switch run.status {
        case .succeeded:
            content.title = String(
                localized: "scheduled.notification.finished",
                bundle: .module
            )
            content.body = job.name
        case .cancelled:
            content.title = String(
                localized: "scheduled.notification.cancelled",
                bundle: .module
            )
            content.body = job.name
        case .failed:
            content.title = String(
                localized: "scheduled.notification.failed",
                bundle: .module
            )
            content.body = job.name
        case .pending, .running, .unknown:
            return
        }
        content.sound = .default
        content.userInfo = [runIDKey: run.id]
        let request = UNNotificationRequest(
            identifier: "scheduled-job-run-\(run.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension Notification.Name {
    static let rubienOpenScheduledJobRun = Notification.Name(
        "com.rubien.scheduled-job.open-run"
    )
}
#endif
