import Foundation

/// `calendar` and `reference` are injectable so tests can pin "now".
public enum DatePresetResolver {
    public static func interval(
        for preset: DatePreset,
        calendar: Calendar = .current,
        reference: Date = Date()
    ) -> DateInterval {
        switch preset {
        case .today:
            return dayInterval(containing: reference, calendar: calendar)
        case .yesterday:
            let day = calendar.date(byAdding: .day, value: -1, to: reference) ?? reference
            return dayInterval(containing: day, calendar: calendar)
        case .tomorrow:
            let day = calendar.date(byAdding: .day, value: 1, to: reference) ?? reference
            return dayInterval(containing: day, calendar: calendar)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: reference)
                ?? dayInterval(containing: reference, calendar: calendar)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: reference)
                ?? dayInterval(containing: reference, calendar: calendar)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: reference)
                ?? dayInterval(containing: reference, calendar: calendar)
        case .nextWeek:
            let next = calendar.date(byAdding: .weekOfYear, value: 1, to: reference) ?? reference
            return calendar.dateInterval(of: .weekOfYear, for: next)
                ?? dayInterval(containing: next, calendar: calendar)
        case .nextMonth:
            let next = calendar.date(byAdding: .month, value: 1, to: reference) ?? reference
            return calendar.dateInterval(of: .month, for: next)
                ?? dayInterval(containing: next, calendar: calendar)
        case .lastNDays(let n):
            let start = calendar.date(byAdding: .day, value: -n, to: startOfDay(reference, calendar: calendar))
                ?? reference
            let end = endOfDay(reference, calendar: calendar)
            return DateInterval(start: start, end: end)
        case .nextNDays(let n):
            let start = startOfDay(reference, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: n, to: endOfDay(reference, calendar: calendar))
                ?? reference
            return DateInterval(start: start, end: end)
        }
    }

    private static func dayInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: date, duration: 86_400)
    }

    private static func startOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date)
            ?? date.addingTimeInterval(86_399)
    }
}
