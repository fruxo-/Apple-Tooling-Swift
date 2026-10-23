import Foundation

/// Restricts recordings by when they were made. All days are interpreted in the
/// calendar's (by default: the user's local) time zone.
public enum DateFilter: Sendable, Equatable {
    /// No date restriction.
    case unrestricted
    /// Exactly one calendar day.
    case day(Date)
    /// An inclusive range of calendar days. Either side may be omitted.
    case range(from: Date?, to: Date?)

    /// The half-open interval `[start, end)` this filter selects.
    /// A `nil` bound means "unbounded on that side".
    public func bounds(calendar: Calendar = .current) -> (start: Date?, end: Date?) {
        switch self {
        case .unrestricted:
            return (nil, nil)
        case .day(let day):
            let start = calendar.startOfDay(for: day)
            return (start, calendar.date(byAdding: .day, value: 1, to: start))
        case .range(let from, let to):
            let start = from.map { calendar.startOfDay(for: $0) }
            let end = to.flatMap {
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
            }
            return (start, end)
        }
    }
}

public struct SearchCriteria: Sendable, Equatable {
    public var date: DateFilter
    /// Boolean expression matched against the recording title; `nil` means no title filter.
    public var titleExpression: SearchExpression?

    public init(date: DateFilter = .unrestricted, titleExpression: SearchExpression? = nil) {
        self.date = date
        self.titleExpression = titleExpression
    }
}

/// Parses `YYYY-MM-DD` strings.
public enum DayParser {
    /// Returns midnight of the given day in `calendar`'s time zone, or `nil` if the
    /// string isn't a valid `YYYY-MM-DD` date.
    public static func parse(_ string: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: string)
    }
}