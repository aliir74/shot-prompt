import Foundation

// T3 stores times as ISO 8601 in UTC, usually with milliseconds. Anything
// else (a bare date, an empty string) gives nil.
public func parseT3Date(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: text) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)
}

// How long ago, in the largest whole unit: now, 5m, 3h, 2d. A time in the
// future counts as now.
public func relativeTime(from date: Date, now: Date) -> String {
    let seconds = max(Int(now.timeIntervalSince(date)), 0)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

// The grey text on a thread's row: its project and how long ago it was active.
public func threadDetail(_ thread: OpenThread, now: Date) -> String {
    guard let d = thread.updatedAt else { return thread.project }
    return "\(thread.project) · \(relativeTime(from: d, now: now))"
}
