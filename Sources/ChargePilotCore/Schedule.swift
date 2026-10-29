import Foundation

public enum ScheduleRunner {
    /// Schedules that missed their time by more than this (the Mac slept through it) are skipped.
    public static let catchUp: TimeInterval = 10 * 60

    /// Items whose time falls in `(from, to]`.
    public static func due(_ items: [ScheduleItem], from: Date, to: Date, calendar: Calendar = .current) -> [ScheduleItem] {
        guard to > from else { return [] }
        let start = max(from, to.addingTimeInterval(-catchUp))
        return items.filter { item in
            guard item.enabled else { return false }
            for dayOffset in [0, -1] {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: to),
                      let fire = calendar.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: day)
                else { continue }
                let weekday = calendar.component(.weekday, from: fire)
                if fire > start, fire <= to, item.weekdays.isEmpty || item.weekdays.contains(weekday) { return true }
            }
            return false
        }
    }

    /// The next time `item` runs after `date`.
    public static func next(_ item: ScheduleItem, after date: Date, calendar: Calendar = .current) -> Date? {
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date),
                  let fire = calendar.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: day)
            else { continue }
            let weekday = calendar.component(.weekday, from: fire)
            if fire > date, item.weekdays.isEmpty || item.weekdays.contains(weekday) { return fire }
        }
        return nil
    }
}

/// The charge limit set in System Settings › Battery, which macOS enforces on its own.
public enum NativeChargeLimit {
    public static func current() -> Int? {
        guard let prefs = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.powerd.charging.plist"),
              let blob = prefs["policies"] as? Data,
              let archive = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any]
        else { return nil }
        let limits = objects.compactMap { object -> Int? in
            guard let policy = object as? [String: Any],
                  let limit = (policy["soclimit"] as? NSNumber)?.intValue,
                  (policy["terminated"] as? NSNumber)?.boolValue != true
            else { return nil }
            return limit
        }
        return limits.filter { $0 > 0 && $0 < 100 }.min()
    }
}
