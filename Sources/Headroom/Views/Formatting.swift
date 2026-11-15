import Foundation

enum Formatting {
    static func relative(_ span: TimeInterval) -> String {
        let seconds = max(span, 0)
        let totalMinutes = Int(seconds / 60)
        let totalHours = totalMinutes / 60
        let totalDays = totalHours / 24
        if totalMinutes < 1 {
            return "<1m"
        }
        if totalHours < 1 {
            return "\(totalMinutes)m"
        }
        if totalDays < 1 {
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(totalHours)h" : "\(totalHours)h \(minutes)m"
        }
        let hours = totalHours % 24
        return hours == 0 ? "\(totalDays)d" : "\(totalDays)d \(hours)h"
    }

    static func resetText(_ resetsAt: Date?, description: String?, now: Date) -> String {
        guard let resetsAt else {
            return description ?? ""
        }

        let time = timeFormatter.string(from: resetsAt)
        let when = Calendar.current.isDate(resetsAt, inSameDayAs: now)
            ? time
            : "\(dayFormatter.string(from: resetsAt)) \(time)"
        return resetsAt <= now ? "Reset due · \(when)" : "Resets in \(relative(resetsAt.timeIntervalSince(now))) · \(when)"
    }

    static func updated(_ date: Date?, now: Date) -> String {
        guard let date else {
            return "Not updated yet"
        }
        let span = relative(now.timeIntervalSince(date))
        return span == "<1m" ? "Updated just now" : "Updated \(span) ago"
    }

    static func intervalText(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Off (manual only)"
        case 1: return "Every minute"
        case 60: return "Every hour"
        case _ where minutes % 60 == 0: return "Every \(minutes / 60) hours"
        default: return "Every \(minutes) minutes"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}
