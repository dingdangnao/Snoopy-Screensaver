import Foundation

public struct SnoopyWeatherSnapshot: Codable, Sendable, Equatable {
    public let conditions: [String]
    public let observedAt: Date
    public let expiresAt: Date
    public let sunrise: Date?
    public let sunset: Date?
    public let previousDayConditions: [String]
    public let source: String?
    public let locationName: String?

    public init(conditions: [String], observedAt: Date = .now,
                expiresAt: Date = .now.addingTimeInterval(3600), sunrise: Date? = nil,
                sunset: Date? = nil, previousDayConditions: [String] = [],
                source: String? = nil, locationName: String? = nil) {
        self.conditions = conditions
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.sunrise = sunrise
        self.sunset = sunset
        self.previousDayConditions = previousDayConditions
        self.source = source
        self.locationName = locationName
    }

    public var isUsable: Bool { expiresAt > .now.addingTimeInterval(-6 * 3600) }
    public var needsRefresh: Bool { expiresAt <= .now.addingTimeInterval(10 * 60) }
}

public struct SnoopyWeatherLocation: Codable, Sendable, Equatable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let timeZoneIdentifier: String?

    public init(name: String, latitude: Double, longitude: Double, timeZoneIdentifier: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// A non-secret preference suite shared by the configuration sheet, optional
/// future helper app, and saver bundle. Playback reads only the cached weather
/// snapshot; refreshes happen asynchronously and never delay media startup.
public enum SnoopyPreferences {
    public static let suiteName = "com.dingdangnao.snoopy.shared"
    public static let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    public static let assetIndexPathKey = "SnoopyAssetIndexPath"
    public static let cityNameKey = "SnoopyCityName"
    public static let weatherEnabledKey = "SnoopyWeatherEnabled"
    public static let weatherOverrideKey = "SnoopyWeatherOverride"
    public static let weatherSnapshotKey = "SnoopyWeatherSnapshot"
    public static let weatherLocationKey = "SnoopyWeatherLocation"
    public static let selectionMemoryKey = "SnoopySelectionMemory"

    public static var weatherEnabled: Bool {
        get {
            if defaults.object(forKey: weatherEnabledKey) != nil {
                return defaults.bool(forKey: weatherEnabledKey)
            }
            return !(defaults.string(forKey: cityNameKey) ?? "").isEmpty
        }
        set { defaults.set(newValue, forKey: weatherEnabledKey) }
    }

    public static func weatherSnapshot() -> SnoopyWeatherSnapshot? {
        guard let data = defaults.data(forKey: weatherSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(SnoopyWeatherSnapshot.self, from: data)
    }

    public static func save(weatherSnapshot: SnoopyWeatherSnapshot) {
        if let data = try? JSONEncoder().encode(weatherSnapshot) {
            defaults.set(data, forKey: weatherSnapshotKey)
        }
    }

    public static func weatherLocation() -> SnoopyWeatherLocation? {
        guard let data = defaults.data(forKey: weatherLocationKey) else { return nil }
        return try? JSONDecoder().decode(SnoopyWeatherLocation.self, from: data)
    }

    public static func save(weatherLocation: SnoopyWeatherLocation) {
        if let data = try? JSONEncoder().encode(weatherLocation) {
            defaults.set(data, forKey: weatherLocationKey)
        }
        defaults.set(weatherLocation.name, forKey: cityNameKey)
    }
}
