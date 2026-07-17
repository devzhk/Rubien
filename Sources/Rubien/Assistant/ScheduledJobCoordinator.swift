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
    @Published private(set) var jobs: [ScheduledJob] = []
    @Published private(set) var upcomingJobs: [ScheduledJob] = []
    @Published private(set) var recentRuns: [ScheduledJobRun] = []
    @Published private(set) var unreadRunCount = 0
    @Published private(set) var activeRun: ScheduledJobRun?

    private let database: AppDatabase
    private let runner: ScheduledJobRunner
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let completionNotifier: (ScheduledJob, ScheduledJobRun) -> Void
    private let usesBackgroundScheduler: Bool
    private let logger = RubienLogger(
        subsystem: "com.rubien.assistant",
        category: "ScheduledJobCoordinator"
    )
    private var timer: Timer?
    private var backgroundActivity: NSBackgroundActivityScheduler?
    private var dueRetryNotBefore: Date?
    private var executionTask: Task<Void, Never>?
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var libraryChangeCancellable: AnyCancellable?

    convenience init(database: AppDatabase = .shared) {
        let contentChannel = MCPContentChannel.resolveBundled()
        let runner = ScheduledJobRunner(
            database: database,
            providerFactory: { kind in
                AssistantProviderFactory.make(kind, contentChannel: contentChannel)
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
        usesBackgroundScheduler: Bool = true
    ) {
        self.database = database
        self.runner = runner
        self.now = now
        self.calendar = calendar
        self.completionNotifier = completionNotifier
        self.usesBackgroundScheduler = usesBackgroundScheduler
    }

    var isRunning: Bool { activeRun != nil }

    func job(id: String) -> ScheduledJob? {
        jobs.first { $0.id == id }
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
        requestNotificationAuthorizationIfNeeded()
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
        requestNotificationAuthorizationIfNeeded()
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
        if isEnabled { requestNotificationAuthorizationIfNeeded() }
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
        runner.cancel()
    }

    func markRunRead(id: String) {
        try? database.markScheduledJobRunRead(id: id)
        refresh()
    }

    func markAllRunsRead() {
        try? database.markAllScheduledJobRunsRead()
        refresh()
    }

    private func didMutate() {
        dueRetryNotBefore = nil
        refresh()
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
        executionTask = Task { [weak self] in
            guard let self else { return }
            var claim: ScheduledJobExecutionClaim? = initialClaim
            while let currentClaim = claim, !Task.isCancelled {
                self.activeRun = currentClaim.run
                self.refresh()
                let finishedRun = await self.runner.execute(currentClaim) { [weak self] in
                    guard let self else { return }
                    self.activeRun = try? self.database.fetchScheduledJobRun(
                        id: currentClaim.run.id
                    )
                    self.refresh()
                }
                if let finishedRun, currentClaim.job.notifyOnCompletion {
                    self.completionNotifier(currentClaim.job, finishedRun)
                }
                self.activeRun = nil
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
        let interval = max(0.1, deadline.timeIntervalSince(now()))
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
        activity.interval = max(1, interval)
        activity.tolerance = min(60, max(1, interval * 0.1))
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                self?.scanForDueJobs()
                completion(.finished)
            }
        }
        backgroundActivity = activity
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
                MainActor.assumeIsolated {
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
            MainActor.assumeIsolated { self?.reconcileClockAndScan() }
        })
        libraryChangeCancellable = LibraryChangeBroadcaster.shared.events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.scanForDueJobs()
                }
            }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard ScheduledJobNotifications.isAvailable,
              jobs.contains(where: { $0.isEnabled && $0.notifyOnCompletion })
        else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        }
    }
}

enum ScheduledJobNotifications {
    static let runIDKey = "scheduledJobRunID"
    /// `UNUserNotificationCenter.current()` raises an Objective-C exception for
    /// a raw SwiftPM executable because it has no application bundle proxy.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func post(job: ScheduledJob, run: ScheduledJobRun) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        switch run.status {
        case .succeeded:
            content.title = "Scheduled job finished"
            content.body = job.name
        case .cancelled:
            content.title = "Scheduled job cancelled"
            content.body = job.name
        case .failed:
            content.title = "Scheduled job failed"
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
