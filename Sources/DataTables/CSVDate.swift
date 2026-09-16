// CSVDate.swift
// DataTables
//
// Strict UTC date parsing for type inference: exactly
// `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS[.frac][Z|±HH:MM]`
// (extended ISO-8601 only — no basic format, no space separator, no
// week/ordinal dates, no leap seconds).
//
// Hand-rolled on purpose: no `DateFormatter` (shared mutable state is
// awkward under Swift 6, per-call construction is slow on 100k rows),
// no locale or timezone dependencies — pure ASCII validation plus
// days-from-civil arithmetic, so results are identical on every
// platform. Anything outside the grammar is not a date (stays text).

import Foundation

/// Strict ISO-8601 subset → UTC epoch seconds.
enum CSVDate: Sendable {
    /// Parse `text` (already trimmed) to epoch seconds, or nil.
    static func epochSeconds(_ text: String) -> Double? {
        let bytes = Array(text.utf8)
        // Minimum: "YYYY-MM-DD" (10 bytes).
        guard bytes.count >= 10 else { return nil }
        guard let year = digits(bytes, 0..<4),
              bytes[4] == 45,  // -
              let month = digits(bytes, 5..<7), (1...12).contains(month),
              bytes[7] == 45,  // -
              let day = digits(bytes, 8..<10), (1...daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        var seconds = Double(daysFromCivil(year: year, month: month, day: day)) * 86400
        guard bytes.count > 10 else { return seconds }  // date-only: midnight UTC
        // Time part: "THH:MM:SS[.frac][Z|±HH:MM]".
        var i = 10
        guard bytes[i] == 84 else { return nil }  // T
        i += 1
        guard bytes.count >= i + 8,
              let hour = digits(bytes, i..<(i + 2)), hour <= 23,
              bytes[i + 2] == 58,  // :
              let minute = digits(bytes, (i + 3)..<(i + 5)), minute <= 59,
              bytes[i + 5] == 58,  // :
              let second = digits(bytes, (i + 6)..<(i + 8)), second <= 59
        else { return nil }
        seconds += Double(hour * 3600 + minute * 60 + second)
        i += 8
        // Optional fractional seconds.
        if i < bytes.count, bytes[i] == 46 {  // .
            i += 1
            let start = i
            while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 { i += 1 }
            let fracDigits = i - start
            guard (1...9).contains(fracDigits) else { return nil }
            var frac = 0.0
            var place = 0.1
            for k in start..<i {
                frac += Double(bytes[k] - 48) * place
                place /= 10
            }
            seconds += frac
        }
        // Zone: end (UTC), Z, or ±HH:MM.
        if i == bytes.count { return seconds }
        guard i < bytes.count else { return nil }
        if bytes[i] == 90 {  // Z
            return i + 1 == bytes.count ? seconds : nil
        }
        guard bytes[i] == 43 || bytes[i] == 45,  // + or -
              bytes.count == i + 6,
              let offHour = digits(bytes, (i + 1)..<(i + 3)), offHour <= 23,
              bytes[i + 3] == 58,
              let offMinute = digits(bytes, (i + 4)..<(i + 6)), offMinute <= 59
        else { return nil }
        let offset = Double(offHour * 3600 + offMinute * 60)
        return bytes[i] == 43 ? seconds - offset : seconds + offset
    }

    /// ASCII decimal digits over `range`, or nil.
    private static func digits(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.upperBound <= bytes.count else { return nil }
        var v = 0
        for k in range {
            guard bytes[k] >= 48, bytes[k] <= 57 else { return nil }
            v = v * 10 + Int(bytes[k] - 48)
        }
        return v
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 (Howard Hinnant's days-from-civil; exact
    /// integer math, valid across the proleptic Gregorian range).
    private static func daysFromCivil(year y0: Int, month m0: Int, day d: Int) -> Int {
        var y = y0
        let m = m0
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = m > 2 ? m - 3 : m + 9
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
