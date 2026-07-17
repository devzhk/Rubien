#if os(macOS)
import Foundation
import XCTest
@testable import Rubien

final class AgentHomeCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }

    func testQuarterUsesCalendarQuarterContainingAnchor() throws {
        let calendar = calendar
        let interval = ActivityHeatmapCalendar.interval(
            for: .quarter,
            anchor: try date(2026, 6, 16, calendar: calendar),
            calendar: calendar)

        XCTAssertEqual(interval.start, try date(2026, 4, 1, calendar: calendar))
        XCTAssertEqual(interval.end, try date(2026, 7, 1, calendar: calendar))
    }

    func testQuarterNavigationMovesByThreeCalendarMonths() throws {
        let calendar = calendar
        let moved = ActivityHeatmapCalendar.date(
            byMoving: try date(2026, 6, 16, calendar: calendar),
            in: .quarter,
            direction: 1,
            calendar: calendar)

        XCTAssertEqual(moved, try date(2026, 9, 16, calendar: calendar))
    }

    func testMonthLabelMovesPastPartialOpeningWeek() throws {
        let calendar = calendar
        let interval = try XCTUnwrap(calendar.dateInterval(
            of: .month,
            for: date(2026, 6, 16, calendar: calendar)))

        let partialWeekStart = try date(2026, 5, 31, calendar: calendar)
        XCTAssertNil(ActivityHeatmapCalendar.monthLabelDate(
            forWeekStarting: partialWeekStart,
            within: interval,
            calendar: calendar))

        let firstFullWeekStart = try date(2026, 6, 7, calendar: calendar)
        XCTAssertEqual(
            ActivityHeatmapCalendar.monthLabelDate(
                forWeekStarting: firstFullWeekStart,
                within: interval,
                calendar: calendar),
            firstFullWeekStart)
    }

    func testMonthLabelStaysOnWeekWhenMonthStartsOnFirstWeekday() throws {
        let calendar = calendar
        let interval = try XCTUnwrap(calendar.dateInterval(
            of: .month,
            for: date(2025, 6, 15, calendar: calendar)))
        let alignedWeekStart = try date(2025, 6, 1, calendar: calendar)

        XCTAssertEqual(
            ActivityHeatmapCalendar.monthLabelDate(
                forWeekStarting: alignedWeekStart,
                within: interval,
                calendar: calendar),
            alignedWeekStart)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day)))
    }
}
#endif
