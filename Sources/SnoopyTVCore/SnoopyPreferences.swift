import Foundation

public struct SnoopyWeatherSnapshot: Codable, Sendable, Equatable {
    public let conditions: [String]
    public let observedAt: Date
    public let expiresAt: Date
    public let sunrise: Date?
    public let sunset: Date?
    public let previousDayConditions: [String]

    public init(conditions: [String], observedAt: Date = .now,
                expiresAt: Date = .now.addingTimeInterval(3600), sunrise: Date? = nil,
                sunset: Date? = nil, previousDayConditions: [String] = []) {
        self.conditions = conditions
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.sunrise = sunrise
        self.sunset = sunset
        self.previousDayConditions = previousDayConditions
    }

    public var isUsable: Bool { expiresAt > .now.addingTimeInterval(-6 * 3600) }
}

/// A non-secret preference suite shared by the settings app and saver bundle.
/// The saver only reads it and never performs weather or CDN network requests.
public enum SnoopyPreferences {
    public static let suiteName = "com.dingdangnao.snoopy.shared"
    public static let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    public static let assetIndexPathKey = "SnoopyAssetIndexPath"
    public static let cityNameKey = "SnoopyCityName"
    public static let weatherOverrideKey = "SnoopyWeatherOverride"
    public static let weatherSnapshotKey = "SnoopyWeatherSnapshot"
    public static let selectionMemoryKey = "SnoopySelectionMemory"

    public static func weatherSnapshot() -> SnoopyWeatherSnapshot? {
        guard let data = defaults.data(forKey: weatherSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(SnoopyWeatherSnapshot.self, from: data)
    }

    public static func save(weatherSnapshot: SnoopyWeatherSnapshot) {
        if let data = try? JSONEncoder().encode(weatherSnapshot) {
            defaults.set(data, forKey: weatherSnapshotKey)
        }
    }
}
