/// The output of the lexical phase: every numeric field exactly as written, plus which forms were
/// used. Nothing here has been range-checked; ``resolve()`` does that.
struct RawComponents: Hashable {
    enum DateForm: UInt8 {
        /// `YYYY-MM-DD` / `YYYYMMDD`: `month` and `day` are month and day-of-month.
        case calendarDate
        /// `YYYY-DDD` / `YYYYDDD`: `day` is the day of the year.
        case ordinalDate
        /// `YYYY-Www-D` / `YYYYWwwD`: `month` is the ISO week, `day` the weekday (Monday = 1).
        case weekDate
        /// `YYYY-Www` / `YYYYWww`: `month` is the ISO week.
        case week
        /// `YYYY-MM`: `month` is the month.
        case month
        /// `YYYY`.
        case year
        /// `YYY`: `year` holds the decade (198 → the 1980s).
        case decade
        /// `YY`: `year` holds the century (19 → 1900...1999).
        case century

        /// Whether a time of day may follow.
        var isComplete: Bool { rawValue <= DateForm.weekDate.rawValue }
    }

    /// The last time field written, which is also the field any fraction belongs to.
    enum TimePrecision: UInt8 {
        case none, hour, minute, second
    }

    enum OffsetForm: UInt8 {
        /// No designator: UTC is assumed.
        case none
        /// `Z` or `z`.
        case utc
        /// `±hh`.
        case hours
        /// `±hhmm` or `±hh:mm`.
        case hoursMinutes
    }

    var dateForm: DateForm = .calendarDate
    /// The year as written, sign included; for ``DateForm/decade`` and ``DateForm/century``, the
    /// decade or century number instead.
    var year: Int32 = 0
    /// Month (calendar and month forms) or ISO week number (week forms).
    var month: UInt8 = 0
    /// Day of month, day of year, or weekday, depending on ``dateForm``.
    var day: UInt16 = 0

    var timePrecision: TimePrecision = .none
    var hour: UInt8 = 0
    var minute: UInt8 = 0
    var second: UInt8 = 0
    /// The decimal fraction of the last time field: its first nine digits as an integer, and how
    /// many digits that is (0 if there's no fraction). `,5` → (5, 1); `.250` → (250, 3).
    var fraction: UInt32 = 0
    var fractionDigits: UInt8 = 0

    var offsetForm: OffsetForm = .none
    /// UTC offset as written: `-05:30` → (5, 30, negative).
    var offsetHour: UInt8 = 0
    var offsetMinute: UInt8 = 0
    var offsetIsNegative = false
}
