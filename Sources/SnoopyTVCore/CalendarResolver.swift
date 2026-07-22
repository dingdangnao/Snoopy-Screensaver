import Foundation

public enum SnoopyCalendarResolver {
    public static func events(for date: Date, calendar: Calendar = .current) -> Set<String> {
        let components = calendar.dateComponents([.month, .day, .weekday, .weekdayOrdinal], from: date)
        guard let month = components.month, let day = components.day else { return [] }
        var events = Set<String>()
        if month == 1 && day == 1 { events.insert("newYearsDay") }
        if month == 2 && day == 14 { events.insert("valentinesDay") }
        if month == 4 && day == 1 { events.insert("aprilFoolsDay") }
        if month == 4 && day == 22 { events.insert("earthDay") }
        if month == 5 && components.weekday == 1 && components.weekdayOrdinal == 2 {
            events.insert("mothersDay")
        }
        if month == 6 && components.weekday == 1 && components.weekdayOrdinal == 3 {
            events.insert("fathersDay")
        }
        if month == 7 && day == 4 { events.insert("fourthOfJuly") }
        if month == 7 && day == 20 { events.insert("peanutsMoonlanding") }
        if month == 8 && day == 10 { events.insert("peanutsSnoopysBirthday") }
        if month == 8 && day == 19 { events.insert("aviationDay") }
        if month == 10 && day == 2 { events.insert("peanutsFirstComicStrip") }
        if month == 10 && day == 4 { events.insert("peanutsSnoopyDebut") }
        if month == 10 && day == 30 { events.insert("peanutsCharlieBrownDay") }
        if month == 12 && day == 16 { events.insert("peanutsBeethovensBirthday") }
        if month == 10 { events.insert("halloweenSeason") }
        if month == 10 && day == 31 { events.insert("halloween") }
        if month == 12 && day == 24 { events.insert("christmasEve"); events.insert("christmasSeason") }
        if month == 12 && day == 25 { events.insert("christmas"); events.insert("christmasSeason") }
        if month == 12 && day == 31 { events.insert("newYearsEve") }
        if month == 11 && components.weekday == 5 && components.weekdayOrdinal == 4 {
            events.insert("thanksgiving"); events.insert("thanksgivingSeason")
            events.insert("peanutsCharlieBrownThanksgiving")
        }
        if month == 11 && day >= 15 { events.insert("thanksgivingSeason") }
        if month == 12 || month == 1 && day <= 6 { events.insert("christmasSeason") }

        // The runtime resolves astronomical season boundaries. These dates are
        // the stable local-calendar approximation used when no location/sun
        // ephemeris is available to an offline screen saver.
        if month == 3 && day == 20 { events.insert("startOfSpring") }
        if month == 6 && day == 21 { events.insert("startOfSummer") }
        if month == 9 && day == 22 { events.insert("startOfFall") }
        if month == 12 && day == 21 { events.insert("startOfWinter") }
        if (month == 3 && day >= 20) || month == 4 || month == 5 || (month == 6 && day < 21) { events.insert("spring") }
        if (month == 6 && day >= 21) || month == 7 || month == 8 || (month == 9 && day < 22) { events.insert("summer") }
        if (month == 9 && day >= 22) || month == 10 || month == 11 || (month == 12 && day < 21) { events.insert("fall") }
        if (month == 12 && day >= 21) || month == 1 || month == 2 || (month == 3 && day < 20) { events.insert("winter") }

        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = calendar.timeZone
        let lunar = chinese.dateComponents([.month, .day], from: date)
        if lunar.month == 1 && lunar.day == 1 { events.insert("lunarNewYear") }
        return events
    }

    public static func routine(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<10: return "morning"
        case 10..<12: return "brunch"
        case 12..<14: return "lunch"
        case 14..<18: return "afternoon"
        case 18..<21: return "dinner"
        case 21..<23: return "bedtime"
        default: return "lateNight"
        }
    }

    /// Returns all routine conditions that are valid at the same time.
    /// The ordinary day-part value is retained so commute material remains an
    /// occasional weighted insert rather than replacing morning and brunch.
    public static func routineConditions(for date: Date, calendar: Calendar = .current) -> Set<String> {
        var conditions: Set<String> = [routine(for: date, calendar: calendar)]
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let commuteWindow = 7 * 60..<(10 * 60 + 30)
        if commuteWindow.contains(minuteOfDay) {
            conditions.insert("goingToSchool")
            conditions.insert("goingToWork")
        }
        return conditions
    }

    public static func hourlyEvents(for date: Date, sunrise: Date?, sunset: Date?, calendar: Calendar = .current) -> Set<String> {
        var events = Set<String>()
        let minute = calendar.component(.minute, from: date)
        if minute <= 5 || minute >= 55 { events.insert("onTheHour") }
        let hour = calendar.component(.hour, from: date)
        if hour == 0 && minute < 15 { events.insert("midnight") }
        if hour == 12 && minute < 15 { events.insert("midday") }
        if let sunrise, abs(date.timeIntervalSince(sunrise)) <= 15 * 60 { events.insert("sunrise") }
        if let sunset, abs(date.timeIntervalSince(sunset)) <= 15 * 60 { events.insert("sunset") }
        return events
    }

    public static func moonCondition(for date: Date) -> String {
        // Synodic phase relative to the known 2000-01-06 new moon.
        let reference = Date(timeIntervalSince1970: 947182440)
        let days = date.timeIntervalSince(reference) / 86_400
        let phase = ((days.truncatingRemainder(dividingBy: 29.53058867)) + 29.53058867).truncatingRemainder(dividingBy: 29.53058867) / 29.53058867
        switch phase {
        case 0.0625..<0.1875: return "moonWaxingCrescent"
        case 0.1875..<0.3125: return "moonFirstQuarter"
        case 0.3125..<0.4375: return "moonWaxingGibbous"
        case 0.4375..<0.5625: return "moonFull"
        case 0.5625..<0.6875: return "moonWaningGibbous"
        case 0.6875..<0.8125: return "moonLastQuarter"
        case 0.8125..<0.9375: return "moonWaningCrescent"
        default: return "moonNew"
        }
    }
}
