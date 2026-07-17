#if os(macOS)
import AppKit
import SwiftUI
import RubienCore

enum ActivityHeatmapRange: String, CaseIterable, Identifiable, Hashable {
    case month
    case quarter
    case year
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ActivityHeatmapCalendar {
    static func interval(
        for range: ActivityHeatmapRange,
        anchor: Date,
        calendar: Calendar
    ) -> DateInterval {
        switch range {
        case .month:
            return calendar.dateInterval(of: .month, for: anchor)!
        case .quarter:
            return calendar.dateInterval(of: .quarter, for: anchor)!
        case .year:
            return calendar.dateInterval(of: .year, for: anchor)!
        }
    }

    static func date(
        byMoving anchor: Date,
        in range: ActivityHeatmapRange,
        direction: Int,
        calendar: Calendar
    ) -> Date? {
        let component: Calendar.Component
        let amount: Int
        switch range {
        case .month: component = .month; amount = direction
        case .quarter: component = .month; amount = 3 * direction
        case .year: component = .year; amount = direction
        }
        return calendar.date(byAdding: component, value: amount, to: anchor)
    }

    static func monthLabelDate(
        forWeekStarting weekStart: Date,
        within interval: DateInterval,
        calendar: Calendar
    ) -> Date? {
        guard weekStart >= interval.start, weekStart < interval.end else { return nil }
        guard calendar.component(.day, from: weekStart) <= 7 else { return nil }
        return weekStart
    }
}

struct AgentHomeView: View {
    @ObservedObject var session: ChatSessionController
    @EnvironmentObject private var scheduledJobs: ScheduledJobCoordinator
    let renderer: ChatTranscriptController
    let database: AppDatabase
    @Binding var draft: String
    @Binding var selectedMentions: [PaperMentionSelection]
    @Binding var activityRailVisible: Bool
    @Binding var activityOverlayPresented: Bool
    @Binding var activityWidth: CGFloat
    let onOpenReference: (Int64) -> Void
    let onOpenPaperSource: (String) -> Void
    let onAddPaperSource: (String) -> Void
    let libraryIsEmpty: Bool
    let onAddPapers: () -> Void
    let onImportPDFs: () -> Void
    let onCompactLayoutChange: (Bool) -> Void
    let onOpenScheduledRun: (ScheduledJobRun) -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = Self.usesCompactLayout(
                availableWidth: geometry.size.width,
                activityWidth: activityWidth)

            ZStack(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 12) {
                    chatSurface

                    if !compact, activityRailVisible {
                        FloatingPanel(width: $activityWidth, range: 360...520) {
                            activityPanel(maximumHeight: max(360, geometry.size.height - 16))
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                if compact, activityOverlayPresented {
                    activityPanel(maximumHeight: max(300, geometry.size.height - 112))
                    .frame(width: min(activityWidth, max(300, geometry.size.width - 24)))
                    .padding(8)
                    .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .padding(8)
            .animation(.easeInOut(duration: 0.2), value: activityRailVisible)
            .animation(.easeInOut(duration: 0.2), value: activityOverlayPresented)
            .onAppear { onCompactLayoutChange(compact) }
            .onChange(of: compact) { _, value in
                if !value { activityOverlayPresented = false }
                onCompactLayoutChange(value)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var chatSurface: some View {
        ChatSurfaceView(
            session: session,
            renderer: renderer,
            draft: $draft,
            selectedMentions: $selectedMentions,
            configuration: .home(
                onOpenReference: onOpenReference,
                onOpenPaperSource: onOpenPaperSource,
                onAddPaperSource: onAddPaperSource,
                libraryIsEmpty: libraryIsEmpty,
                onAddPapers: onAddPapers,
                onImportPDFs: onImportPDFs,
                scheduledJobs: scheduledJobs,
                onOpenScheduledRun: onOpenScheduledRun))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.chatSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: 0.5)
            }
    }

    private func activityPanel(maximumHeight: CGFloat) -> some View {
        ReadingActivityPanel(
            database: database,
            maximumHeight: maximumHeight,
            onOpenReference: onOpenReference)
    }

    static func usesCompactLayout(availableWidth: CGFloat, activityWidth: CGFloat) -> Bool {
        availableWidth < AssistantSidebarMetrics.minimumWidth
            + min(max(activityWidth, 360), 520)
            + 44
    }
}

private struct ReadingActivityPanel: View {
    let database: AppDatabase
    let maximumHeight: CGFloat
    let onOpenReference: (Int64) -> Void

    @State private var snapshot: ReadingActivitySnapshot?
    @State private var errorMessage: String?
    @State private var range: ActivityHeatmapRange = ActivityHeatmapRange(
        rawValue: RubienPreferences.activityHeatmapRange) ?? .quarter
    @State private var anchor = Date()
    @State private var showingInfo = false
    @State private var refreshTrigger = 0
    @State private var reloadGeneration = 0
    @State private var notificationReloadTask: Task<Void, Never>?
    @State private var recentPaperCards: [Int64: ChatPaper] = [:]

    private var calendar: Calendar { AppDatabase.activityCalendar() }
    private var interval: DateInterval {
        ActivityHeatmapCalendar.interval(for: range, anchor: anchor, calendar: calendar)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            panelContent
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                panelContent
            }
            .frame(maxHeight: maximumHeight)
        }
        .neutralGlassCard(cornerRadius: 14)
        .task(id: reloadID) { await reload() }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                refreshTrigger &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rubienActivityDidChange)) { _ in
            scheduleNotificationReload()
        }
        .onReceive(LibraryChangeBroadcaster.shared.events) { _ in
            // Cross-process CLI clears and CloudKit-driven library invalidations
            // travel through the shared library broadcaster rather than the local
            // reader notification. Coalesce both paths through one reload task.
            scheduleNotificationReload()
        }
        .onDisappear {
            notificationReloadTask?.cancel()
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Reading Activity").font(.title3.weight(.semibold))
                Spacer()
                Button { showingInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(AgentHomeHoverButtonStyle())
                .help("About reading activity")
                .popover(
                    isPresented: $showingInfo,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .trailing
                ) {
                    Text("Rubien estimates reading time while its PDF or web reader is the active window. Sessions under one minute are excluded; activity syncs through iCloud when enabled.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(width: 280)
                }
            }

            if !RubienPreferences.recordReadingActivity {
                Label("Recording off on this Mac", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let snapshot {
                coverage(snapshot.coverage)
                if errorMessage != nil {
                    HStack(spacing: 6) {
                        Label("Couldn’t refresh activity", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { refreshTrigger &+= 1 }
                            .font(.caption2)
                            .buttonStyle(AgentHomeHoverButtonStyle())
                    }
                }
                metricGrid(snapshot)
                heatmap(snapshot)
                recent(snapshot.recentPapers)
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity unavailable").font(.headline)
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { refreshTrigger &+= 1 }
                        .buttonStyle(AgentHomeHoverButtonStyle())
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func coverage(_ coverage: ActivityCoverage) -> some View {
        if let reset = coverage.readingResetAt {
            Text("Reading activity reset \(reset.formatted(date: .abbreviated, time: .omitted)); earlier activity is excluded.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func metricGrid(_ value: ReadingActivitySnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metric(
                "Papers read", "\(value.papersReadTracked)", "book.pages",
                help: "Distinct papers active in Rubien’s PDF or web reader for at least 60 seconds. This is engagement, not proof of completion.")
            metric(
                "Total reading time", formatDuration(value.estimatedActiveSecondsTracked), "clock",
                detail: "Estimated",
                help: "Total estimated foreground-reader time on qualifying paper-days since tracking began or the last reset.")
            metric("Papers this week", "\(value.papersReadThisWeek)", "calendar")
            metric("Time this week", formatDuration(value.estimatedActiveSecondsThisWeek), "clock.badge", detail: "Estimated")
            metric(
                "AI sessions", "\(value.assistantSessionsTracked)", "sparkles",
                detail: effectivePeriod(value.coverage.assistantResetAt))
            metric(
                "Streak", dayCount(value.currentStreakDays), "flame",
                detail: "Longest \(dayCount(value.longestStreakDays))")
        }
    }

    private func metric(
        _ title: String,
        _ value: String,
        _ icon: String,
        detail: String? = nil,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .help(help ?? title)
    }

    private func heatmap(_ value: ReadingActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DraggableSegmentedControl(
                selection: $range,
                items: ActivityHeatmapRange.allCases.map {
                    (label: $0.title, value: $0)
                })
            .accessibilityLabel("Reading activity range")
            .onChange(of: range) { _, value in
                RubienPreferences.activityHeatmapRange = value.rawValue
            }

            HStack {
                Button { moveAnchor(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(AgentHomeHoverButtonStyle())
                    .help("Previous \(range.title.lowercased())")
                Text(rangeLabel)
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                Button { moveAnchor(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(AgentHomeHoverButtonStyle())
                    .disabled(!canMoveForward)
                    .help("Next \(range.title.lowercased())")
            }

            HeatmapGrid(
                range: range,
                interval: interval,
                dailyActivity: value.dailyActivity,
                calendar: calendar)

            HStack(spacing: 7) {
                ForEach(Array(HeatmapGrid.legend.enumerated()), id: \.offset) { index, label in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(HeatmapGrid.color(for: index + 1))
                            .frame(width: 11, height: 11)
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func recent(_ papers: [RecentReading]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently read").font(.headline)
            if papers.isEmpty {
                Text("Keep a paper active in Rubien’s reader for at least one minute to begin recording activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(papers, id: \.referenceId) { paper in
                    ActivityPaperCard(
                        paper: recentPaperCards[paper.referenceId] ?? ChatPaper(
                            kind: .library,
                            referenceId: paper.referenceId,
                            url: nil,
                            title: paper.title,
                            authors: paper.byline,
                            year: nil,
                            badge: "Library"),
                        action: { onOpenReference(paper.referenceId) })
                }
            }
        }
    }

    private var reloadID: String {
        "\(range.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)-\(refreshTrigger)"
    }

    @MainActor
    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let start = LocalDay(date: interval.start, calendar: calendar)
        let endDate = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let end = LocalDay(date: endDate, calendar: calendar)
        do {
            let loaded = try await Task.detached(priority: .utility) {
                let snapshot = try database.fetchReadingActivitySnapshot(
                    dailyActivityStartDay: start,
                    dailyActivityEndDay: end)
                return (snapshot, Self.paperCards(for: snapshot, database: database))
            }.value
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            snapshot = loaded.0
            recentPaperCards = loaded.1
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleNotificationReload() {
        notificationReloadTask?.cancel()
        notificationReloadTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            refreshTrigger &+= 1
        }
    }

    private func moveAnchor(_ direction: Int) {
        if let moved = ActivityHeatmapCalendar.date(
            byMoving: anchor,
            in: range,
            direction: direction,
            calendar: calendar
        ) {
            anchor = min(moved, Date())
        }
    }

    private var canMoveForward: Bool {
        interval.end <= Date()
    }

    private var rangeLabel: String {
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private func formatDuration(_ seconds: Int64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func dayCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "day" : "days")"
    }

    private func effectivePeriod(_ reset: Date?) -> String {
        if let reset { return "Since \(reset.formatted(date: .abbreviated, time: .omitted))" }
        return "Since tracking began"
    }

    nonisolated private static func paperCards(
        for snapshot: ReadingActivitySnapshot,
        database: AppDatabase
    ) -> [Int64: ChatPaper] {
        let ids = snapshot.recentPapers.map(\.referenceId)
        let references = (try? database.fetchReferences(ids: ids)) ?? []
        return Dictionary(uniqueKeysWithValues: references.compactMap { reference in
            guard let id = reference.id else { return nil }
            let badge: String
            if reference.hasPDFInCache(in: database) {
                badge = "PDF"
            } else if reference.canOpenWebReader {
                badge = "Web"
            } else {
                badge = "Library"
            }
            return (id, ChatPaper(
                kind: .library,
                referenceId: id,
                url: nil,
                title: reference.title,
                authors: reference.authors.displayString,
                year: reference.year,
                badge: badge))
        })
    }
}

/// Shared hover treatment for the Activity panel's otherwise-borderless controls.
/// Disabled controls stay visually inert so hover always means "clickable."
private struct AgentHomeHoverButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlight(configuration: configuration)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                hovered = isEnabled && hovering
            }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func highlight(configuration: Configuration) -> Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return Color.primary.opacity(0.10) }
        return hovered ? Color.primary.opacity(0.06) : .clear
    }
}

/// Native counterpart of the Assistant transcript's paper card. The whole card
/// is one button and carries only the agreed presentation metadata: canonical
/// title, compact authors, year, and source/status badge.
private struct ActivityPaperCard: View {
    let paper: ChatPaper
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(paper.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .help(paper.title)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let byline = paper.authors?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !byline.isEmpty
                    {
                        Text(briefByline(byline))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(byline)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text(paper.year.map { String($0) } ?? "—")
                        Text("·").foregroundStyle(.tertiary)
                        Text(paper.badge).lineLimit(1)
                    }
                    .fixedSize()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.06) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        Color.primary.opacity(hovered ? 0.16 : 0.09),
                        lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .help("Open \(paper.title)")
    }

    private func briefByline(_ full: String) -> String {
        let authors = full.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard authors.count > 2 else { return full }
        return authors.prefix(2).joined(separator: ", ") + ", et al."
    }
}

private struct HeatmapGrid: View {
    let range: ActivityHeatmapRange
    let interval: DateInterval
    let dailyActivity: [DailyReadingActivity]
    let calendar: Calendar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredDay: HoveredDay?

    private struct LayoutMetrics {
        let daySize: CGFloat
        let daySpacing: CGFloat
        let cornerRadius: CGFloat
        let hoverScale: CGFloat
        let weekdayWidth: CGFloat
        let labelHeight: CGFloat
        let labelFontSize: CGFloat
    }

    private struct HoveredDay: Equatable {
        let day: LocalDay
        let date: Date
        let estimatedActiveSeconds: Int64
        let paperCount: Int
    }

    private var metrics: LayoutMetrics {
        LayoutMetrics(
            daySize: 12,
            daySpacing: 4,
            cornerRadius: 3,
            hoverScale: 1.30,
            weekdayWidth: 18,
            labelHeight: 14,
            labelFontSize: 8.5)
    }

    private var days: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? interval.start
        let visibleEnd = calendar.date(byAdding: .second, value: -1, to: interval.end) ?? interval.end
        let endWeek = calendar.dateInterval(of: .weekOfYear, for: visibleEnd)?.end ?? interval.end
        var result: [Date] = []
        var cursor = start
        while cursor < endWeek {
            result.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return result
    }

    private var weeks: [[Date]] {
        stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
    }

    private var weekdayLabels: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let start = max(0, min(6, calendar.firstWeekday - 1))
        return Array(symbols[start...]) + Array(symbols[..<start])
    }

    var body: some View {
        let activityByDay = Dictionary(
            uniqueKeysWithValues: dailyActivity.map { ($0.localDay, $0) })
        let visibleWeeks = weeks
        VStack(spacing: 7) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 5) {
                        VStack(spacing: metrics.daySpacing) {
                            Color.clear
                                .frame(width: metrics.weekdayWidth, height: metrics.labelHeight)
                            ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                                Text(label)
                                    .font(.system(size: metrics.labelFontSize))
                                    .foregroundStyle(.tertiary)
                                    .frame(
                                        width: metrics.weekdayWidth,
                                        height: metrics.daySize,
                                        alignment: .trailing)
                            }
                        }

                        HStack(alignment: .top, spacing: metrics.daySpacing) {
                            ForEach(visibleWeeks.indices, id: \.self) { index in
                                let week = visibleWeeks[index]
                                let containsHoveredDay = week.contains {
                                    LocalDay(date: $0, calendar: calendar) == hoveredDay?.day
                                }
                                VStack(alignment: .leading, spacing: metrics.daySpacing) {
                                    Text(monthLabel(for: week))
                                        .font(.system(
                                            size: metrics.labelFontSize,
                                            weight: .medium))
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(
                                            width: metrics.daySize,
                                            height: metrics.labelHeight,
                                            alignment: .leading)

                                    ForEach(week, id: \.self) { date in
                                        dayCell(date, activityByDay: activityByDay)
                                    }
                                }
                                .zIndex(containsHoveredDay ? 1 : 0)
                            }
                        }
                    }
                    // Center Month, Quarter, and Year whenever their natural
                    // content fits. Extremely narrow overlays still scroll.
                    .frame(minWidth: geometry.size.width, alignment: .center)
                }
            }
            .frame(height: gridHeight)

            hoverReadout
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading activity heatmap")
        .accessibilityValue("\(dailyActivity.count) recorded reading days in this range")
        .onChange(of: range) { _, _ in hoveredDay = nil }
        .onChange(of: interval) { _, _ in hoveredDay = nil }
    }

    private var gridHeight: CGFloat {
        metrics.labelHeight
            + (7 * metrics.daySize)
            + (7 * metrics.daySpacing)
    }

    @ViewBuilder
    private var hoverReadout: some View {
        if let hoveredDay {
            HStack(spacing: 5) {
                Text(hoveredDay.date.formatted(.dateTime.month(.abbreviated).day().year()))
                Text("·").foregroundStyle(.tertiary)
                Text(readingTimeText(hoveredDay.estimatedActiveSeconds))
                    .fontWeight(.semibold)
                if hoveredDay.paperCount > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(hoveredDay.paperCount) \(hoveredDay.paperCount == 1 ? "paper" : "papers")")
                }
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.045), in: Capsule())
            .transition(.opacity)
        } else {
            Text("Hover a day to see reading time")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func dayCell(
        _ date: Date,
        activityByDay: [LocalDay: DailyReadingActivity]
    ) -> some View {
        let day = LocalDay(date: date, calendar: calendar)
        let value = activityByDay[day]
        let isInRange = date >= interval.start && date < interval.end
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: Date())
        let isAvailable = isInRange && !isFuture
        let isHovered = hoveredDay?.day == day
        return RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .fill(isInRange && !isFuture
                ? Self.color(for: Self.level(value?.estimatedActiveSeconds ?? 0))
                : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isHovered ? 0.28 : (isInRange ? 0.08 : 0.025)),
                        lineWidth: isHovered ? 0.9 : 0.5)
            }
            .frame(width: metrics.daySize, height: metrics.daySize)
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(isHovered ? metrics.hoverScale : 1)
            .shadow(
                color: isHovered ? Color.accentColor.opacity(0.28) : .clear,
                radius: isHovered ? 3 : 0)
            .zIndex(isHovered ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { inside in
                guard isAvailable else { return }
                if inside {
                    hoveredDay = HoveredDay(
                        day: day,
                        date: date,
                        estimatedActiveSeconds: value?.estimatedActiveSeconds ?? 0,
                        paperCount: value?.paperCount ?? 0)
                } else if hoveredDay?.day == day {
                    hoveredDay = nil
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.72),
                value: isHovered)
            .help(isAvailable
                ? helpText(date: date, value: value)
                : (isFuture ? "Future date" : "Outside the selected range"))
    }

    private func monthLabel(for week: [Date]) -> String {
        let labelDate = week.first.flatMap {
            ActivityHeatmapCalendar.monthLabelDate(
                forWeekStarting: $0,
                within: interval,
                calendar: calendar)
        }
        return labelDate?.formatted(.dateTime.month(.abbreviated)) ?? ""
    }

    static let legend = ["1–15m", "15–30m", "30–60m", "1–2h", "2h+"]

    static func level(_ seconds: Int64) -> Int {
        switch seconds {
        case ..<60: 0
        case ..<900: 1
        case ..<1800: 2
        case ..<3600: 3
        case ..<7200: 4
        default: 5
        }
    }

    static func color(for level: Int) -> Color {
        guard level > 0 else { return Color.primary.opacity(0.035) }
        return Color.accentColor.opacity([0, 0.22, 0.38, 0.56, 0.75, 0.95][min(level, 5)])
    }

    private func helpText(date: Date, value: DailyReadingActivity?) -> String {
        let seconds = value?.estimatedActiveSeconds ?? 0
        let papers = value?.paperCount ?? 0
        let formattedDate = date.formatted(date: .long, time: .omitted)
        return "\(formattedDate): \(readingTimeText(seconds)), \(papers) \(papers == 1 ? "paper" : "papers")"
    }

    private func readingTimeText(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "No qualifying reading" }
        if seconds < 60 { return "\(seconds)s estimated" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m estimated" }
        if hours > 0 { return "\(hours)h estimated" }
        return "\(minutes)m estimated"
    }
}
#endif
