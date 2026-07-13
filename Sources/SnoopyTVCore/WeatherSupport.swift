import Foundation

public enum SnoopyWeatherError: LocalizedError {
    case invalidCity
    case locationNotFound
    case invalidResponse
    case service(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCity: return "请填写至少两个字符的城市名称。"
        case .locationNotFound: return "没有找到这个所在地，请尝试填写“城市, 国家/地区”。"
        case .invalidResponse: return "天气服务返回了无法识别的数据。"
        case .service(let message): return "天气服务暂时不可用：\(message)"
        }
    }
}

public enum SnoopyWeatherConditionMapper {
    public static func conditions(wmoCode: Int, windSpeed: Double = 0, isDay: Bool = true) -> [String] {
        var values: Set<String>
        switch wmoCode {
        case 0, 1:
            values = isDay ? ["clear", "sunny"] : ["clear"]
        case 2, 3:
            values = ["cloudy"]
        case 45, 48:
            values = ["foggy"]
        case 51...55, 61...65, 80...82:
            values = ["rainy"]
        case 56, 57, 66, 67:
            values = ["icy", "rainy"]
        case 71...77, 85, 86:
            values = ["snowy"]
        case 95...99:
            values = ["stormy"]
        default:
            values = []
        }
        if windSpeed >= 29 { values.insert("windy") }
        return values.sorted()
    }
}

public struct SnoopyWeatherClient: Sendable {
    public init() {}

    public func resolve(city rawCity: String, language: String = "zh") async throws -> SnoopyWeatherLocation {
        let city = rawCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard city.count >= 2 else { throw SnoopyWeatherError.invalidCity }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        let response: GeocodingResponse = try await request(components.url!)
        guard let place = response.results?.first else { throw SnoopyWeatherError.locationNotFound }
        let nameParts = [place.name, place.admin1, place.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let displayName = nameParts.filter { seen.insert($0).inserted }.joined(separator: " · ")
        return SnoopyWeatherLocation(
            name: displayName.isEmpty ? city : displayName,
            latitude: place.latitude,
            longitude: place.longitude,
            timeZoneIdentifier: place.timezone
        )
    }

    public func fetch(location: SnoopyWeatherLocation) async throws -> SnoopyWeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        let response: ForecastResponse = try await request(components.url!)
        guard let current = response.current else { throw SnoopyWeatherError.invalidResponse }
        let timeZone = TimeZone(identifier: response.timezone ?? location.timeZoneIdentifier ?? "") ?? .current
        let sunrise = response.daily?.sunrise.first.flatMap { parseLocalDate($0, timeZone: timeZone) }
        let sunset = response.daily?.sunset.first.flatMap { parseLocalDate($0, timeZone: timeZone) }
        return SnoopyWeatherSnapshot(
            conditions: SnoopyWeatherConditionMapper.conditions(
                wmoCode: current.weatherCode,
                windSpeed: current.windSpeed ?? 0,
                isDay: current.isDay != 0
            ),
            observedAt: parseLocalDate(current.time, timeZone: timeZone) ?? .now,
            expiresAt: .now.addingTimeInterval(3600),
            sunrise: sunrise,
            sunset: sunset,
            source: "Open-Meteo",
            locationName: location.name
        )
    }

    private func request<Response: Decodable>(_ url: URL) async throws -> Response {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SnoopyWeatherError.invalidResponse
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as SnoopyWeatherError {
            throw error
        } catch {
            throw SnoopyWeatherError.service(error.localizedDescription)
        }
    }

    private func parseLocalDate(_ value: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: value)
    }

    private struct GeocodingResponse: Decodable {
        let results: [Place]?
    }

    private struct Place: Decodable {
        let name: String?
        let latitude: Double
        let longitude: Double
        let timezone: String?
        let country: String?
        let admin1: String?
    }

    private struct ForecastResponse: Decodable {
        let timezone: String?
        let current: Current?
        let daily: Daily?
    }

    private struct Current: Decodable {
        let time: String
        let weatherCode: Int
        let windSpeed: Double?
        let isDay: Int

        private enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
            case isDay = "is_day"
        }
    }

    private struct Daily: Decodable {
        let sunrise: [String]
        let sunset: [String]
    }
}
