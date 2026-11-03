// Adapter for the CalConnect ISO 8601 machine-readable test suite
// (https://github.com/CalConnect/iso-8601-test-suite), speaking its newline-delimited JSON
// `exec:` protocol on stdin/stdout:
//
//     ruby scripts/run-tests --adapter "exec:<path to built iso8601-suite-adapter>"
//
// Per the suite's adapter purity rules (adapters/RULES.adoc), this adapter only translates between
// the protocol and NativeISO8601's public API. Components come from `ISO8601.timestamp(from:)`,
// which reports the fields exactly as written; nothing is derived here. Equivalence compares the
// library's resolved `Date`s. Generation is not supported: the library has no formatter.

import Foundation
import NativeISO8601

nonisolated(unsafe) var parsed: [String: ISO8601.Timestamp] = [:]
nonisolated(unsafe) var nextHandle = 0

func info() -> Any {
    ["name": "NativeISO8601", "language": "swift", "version": "0.2.0"]
}

func declaredConformanceClasses() -> Any {
    [
        "conf-class:fundamentals",
        "conf-class:calendar-date",
        "conf-class:ordinal-date",
        "conf-class:week-date",
        "conf-class:time-of-day",
        "conf-class:date-and-time",
    ]
}

func declaredProfiles() -> Any {
    ["profile:iso-8601-1-core", "profile:rfc-3339"]
}

func tryParse(_ params: [String: Any]) -> Any {
    let expression = params["expression"] as? String ?? ""
    // NativeISO8601 has a single entry point, used for both "dedicated" and "undifferentiated" modes.
    do {
        let timestamp = try ISO8601.timestamp(from: expression)
        nextHandle += 1
        let handle = "h\(nextHandle)"
        parsed[handle] = timestamp
        return ["valid": true, "parsed": handle, "api": "ISO8601.timestamp(from:)"]
    } catch {
        return ["valid": false, "error": error.description, "api": "ISO8601.timestamp(from:)"]
    }
}

func extractComponents(_ params: [String: Any]) -> Any {
    guard let handle = params["parsed"] as? String, let timestamp = parsed[handle] else { return [String: Any]() }
    var result: [String: Any] = [:]

    switch timestamp.dateValue {
    case let .calendarDate(year, month, day): result["calendar"] = ["year": year, "month": month, "day": day]
    case let .month(year, month): result["calendar"] = ["year": year, "month": month]
    case let .year(year): result["calendar"] = ["year": year]
    case let .decade(decade): result["calendar"] = ["decade": decade]
    case let .century(century): result["calendar"] = ["century": century]
    case let .ordinalDate(year, dayOfYear): result["ordinal"] = ["year": year, "day_of_year": dayOfYear]
    case let .week(year, week): result["week"] = ["week_year": year, "week": week]
    case let .weekDate(year, week, weekday): result["week"] = ["week_year": year, "week": week, "day_of_week": weekday]
    }

    if let time = timestamp.time {
        var fields: [String: Any] = ["hour": time.hour]
        if let minute = time.minute { fields["minute"] = minute }
        if let second = time.second { fields["second"] = second }
        if let fraction = time.fraction {
            // The fraction belongs to the last field written.
            let key = time.second != nil ? "fractional_second" : time.minute != nil ? "fractional_minute" : "fractional_hour"
            fields[key] = ["value": fraction.value, "precision": fraction.digits]
        }
        if let offset = timestamp.utcOffset {
            fields["utc_offset"] = ["sign": offset.isNegative ? "-" : "+", "hours": offset.hours, "minutes": offset.minutes]
        }
        result["time"] = fields
    }
    return result
}

func equivalent(_ params: [String: Any]) -> Any {
    guard let a = (params["parsed_a"] as? String).flatMap({ parsed[$0] }),
          let b = (params["parsed_b"] as? String).flatMap({ parsed[$0] })
    else { return NSNull() }
    return a.date == b.date
}

func respond(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"error":"encoding failed"}"#.utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

while let line = readLine() {
    guard !line.isEmpty,
          let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let method = request["method"] as? String
    else {
        respond(["error": "malformed request"])
        continue
    }
    let params = request["params"] as? [String: Any] ?? [:]
    let result: Any? = switch method {
    case "info": info()
    case "declared_conformance_classes": declaredConformanceClasses()
    case "declared_profiles": declaredProfiles()
    case "qualification_notes": [Any]() // No workarounds: every component comes from the library.
    case "try_parse": tryParse(params)
    case "extract_components": extractComponents(params)
    case "generate": NSNull() // No formatter in NativeISO8601.
    case "equivalent": equivalent(params)
    case "run_arithmetic": ["result": "not-supported", "notes": "NativeISO8601 does not implement ISO 8601 arithmetic"]
    default: nil
    }
    if let result {
        respond(["result": result])
    } else {
        respond(["error": "Unknown method: \(method)"])
    }
}
