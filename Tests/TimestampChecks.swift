import Foundation

// Run: swiftc HermesPocket/Models.swift Tests/TimestampChecks.swift -o /tmp/agentos-time-check && /tmp/agentos-time-check
@main
struct TimestampChecks {
    static func main() {
        let morning = Date(timeIntervalSince1970: 1_700_006_400)
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: morning)
        let noon = calendar.date(byAdding: .hour, value: 12, to: midnight)!
        assert(ChatTimestamp.label(midnight, now: midnight).hasSuffix("12:00 AM"))
        assert(ChatTimestamp.label(noon, now: noon).hasSuffix("12:00 PM"))
        let nextYear = calendar.date(byAdding: .year, value: 1, to: noon)!
        assert(ChatTimestamp.label(noon, now: nextYear).contains(String(calendar.component(.year, from: noon))))
        assert(ChatMessage(role: .user, content: "test").timestamp == nil)
        print("Timestamp checks passed: midnight, noon, cross-year dates, and missing timestamps")
    }
}
