import Foundation

@main
enum WeatherSmoke {
    static func main() async throws {
        let city = CommandLine.arguments.dropFirst().first ?? "Shanghai"
        let client = SnoopyWeatherClient()
        let location = try await client.resolve(city: city)
        let snapshot = try await client.fetch(location: location)
        let output: [String: Any] = [
            "location": location.name,
            "latitude": location.latitude,
            "longitude": location.longitude,
            "conditions": snapshot.conditions,
            "source": snapshot.source ?? "unknown",
            "sunrise": snapshot.sunrise?.description ?? "none",
            "sunset": snapshot.sunset?.description ?? "none",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: output, options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }
}
