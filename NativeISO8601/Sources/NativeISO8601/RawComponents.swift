/// The output of the lexical phase: every numeric field exactly as written, plus which date form
/// was used. Nothing here has been range-checked; ``resolve()`` does that.
struct RawComponents: Hashable {
    enum DateForm: UInt8 {
        /// `YYYY-MM-DD` / `YYYYMMDD`: `month` and `day` are month and day-of-month.
        case calendar
        /// `YYYY-DDD` / `YYYYDDD`: `day` is the day of the year.
        case ordinal
        /// `YYYY-Www-D` / `YYYYWwwD`: `month` is the ISO week, `day` the weekday (Monday = 1).
        case week
    }

    var form: DateForm = .calendar
    /// 0000...9999.
    var year: Int32 = 0
    /// Month (calendar form) or ISO week number (week form).
    var month: UInt8 = 0
    /// Day of month, day of year, or weekday, depending on ``form``.
    var day: UInt16 = 0
    var hour: UInt8 = 0
    var minute: UInt8 = 0
    var second: UInt8 = 0
    /// The fractional second scaled to nanoseconds; digits beyond the ninth are truncated.
    var nanosecond: UInt32 = 0
    /// UTC offset as written: `-05:30` → (5, 30, negative). `Z` or no designator → zero.
    var offsetHour: UInt8 = 0
    var offsetMinute: UInt8 = 0
    var offsetIsNegative = false
}
