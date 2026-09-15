import CoreLocation
import Foundation
import OperatorCore
import OSLog
#if canImport(WeatherKit)
import WeatherKit
#endif

// Weather takes an explicit coordinate rather than reaching for the phone's
// location itself. The agent calls location.get first if it needs to, and
// that keeps one permission prompt attached to one capability: asking about
// the weather in a city you are not in should not read where you are.
//
// Two obligations that are not code and must not be forgotten:
//
//  - WeatherKit needs the com.apple.developer.weatherkit entitlement on the
//    App ID. Unlike every other capability added here it is not a permission
//    string; it is a capability enabled on a paid Apple Developer account,
//    and without it every call fails at runtime.
//  - Apple requires visible attribution — the Apple Weather mark and a link
//    to the legal page — wherever this data is shown. That is a UI debt this
//    service cannot discharge on its own.

struct WeatherReading: Sendable, Equatable {
    let temperatureCelsius: Double
    let apparentCelsius: Double?
    let condition: String
    let humidity: Double?
    let windKilometresPerHour: Double?
    let highCelsius: Double?
    let lowCelsius: Double?
    let attribution: WeatherCardAttribution
    init(temperatureCelsius: Double, apparentCelsius: Double?, condition: String, humidity: Double?, windKilometresPerHour: Double?, highCelsius: Double?, lowCelsius: Double?, attribution: WeatherCardAttribution) { self.temperatureCelsius = temperatureCelsius; self.apparentCelsius = apparentCelsius; self.condition = condition; self.humidity = humidity; self.windKilometresPerHour = windKilometresPerHour; self.highCelsius = highCelsius; self.lowCelsius = lowCelsius; self.attribution = attribution }
}

protocol WeatherSource: Sendable {
    func reading(latitude: Double, longitude: Double) async throws -> WeatherReading
}

@MainActor
final class ForegroundWeatherService: GatewayNodeCommandHandler {
    private struct Payload: Encodable {
        let temperatureC: Double
        let feelsLikeC: Double?
        let condition: String
        let humidity: Double?
        let windKph: Double?
        let highC: Double?
        let lowC: Double?
        let attribution: String
    }

    /// Apple's terms require the attribution to travel with the data, so it
    /// is part of the payload rather than something a caller may forget.
    static let attribution = "Weather data provided by Apple Weather"

    private let source: any WeatherSource
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-weather")
    private let recordCard: @MainActor @Sendable (WeatherCard) async throws -> Void

    init(source: any WeatherSource, recordCard: @escaping @MainActor @Sendable (WeatherCard) async throws -> Void) { self.source = source; self.recordCard = recordCard }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "weather.forecast" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let point = Self.coordinate(from: paramsJSON) else {
            self.logger.info("[weather] refused branch=invalid_params")
            return .failure(
                code: "INVALID_REQUEST",
                message: "weather.forecast requires latitude between -90 and 90 and longitude between -180 and 180")
        }
        // The only network call among the native capabilities, so the one
        // that most needed bounding. The double optional is deliberate: the
        // outer nil is the deadline passing, the inner nil is the backend
        // failing, and those are different things to tell the agent.
        let outcome: WeatherReading?? = await GatewayDeadline.run(
            milliseconds: GatewayDeadline.bounded(timeoutMilliseconds),
            { [source] in try? await source.reading(latitude: point.0, longitude: point.1) })
        let reading: WeatherReading
        switch outcome {
        case .none:
            self.logger.error("[weather] failed branch=timeout")
            return .failure(code: "TIMEOUT", message: "The forecast took too long to arrive")
        case .some(.none):
            // The error is not forwarded: a weather backend's message is not
            // something to hand an agent verbatim.
            self.logger.error("[weather] failed branch=source_unavailable")
            return .failure(code: "WEATHER_UNAVAILABLE", message: "Operator could not read the forecast")
        case .some(.some(let value)):
            reading = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(
            temperatureC: reading.temperatureCelsius,
            feelsLikeC: reading.apparentCelsius,
            condition: reading.condition,
            humidity: reading.humidity,
            windKph: reading.windKilometresPerHour,
            highC: reading.highCelsius,
            lowC: reading.lowCelsius,
            attribution: Self.attribution)),
            let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[weather] failed branch=encode")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not read the forecast")
        }
        self.logger.info("[weather] returned condition_length=\(reading.condition.count)")
        let card = WeatherCard(temperatureCelsius: reading.temperatureCelsius, apparentCelsius: reading.apparentCelsius, condition: reading.condition, humidity: reading.humidity, windKilometresPerHour: reading.windKilometresPerHour, highCelsius: reading.highCelsius, lowCelsius: reading.lowCelsius, attribution: reading.attribution)
        do { try await self.recordCard(card) }
        catch {
            self.logger.error("[weather] failed branch=card_persistence")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not save the forecast")
        }
        return .success(payloadJSON: payloadJSON)
    }

    static func coordinate(from paramsJSON: String?) -> (Double, Double)? {
        guard let paramsJSON, paramsJSON.utf8.count <= 4096,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              Set(object.keys) == ["latitude", "longitude"],
              let latitude = JSONNumber.double(object["latitude"]!),
              let longitude = JSONNumber.double(object["longitude"]!),
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude)
        else { return nil }
        return (latitude, longitude)
    }
}

#if canImport(WeatherKit)
struct SystemWeatherSource: WeatherSource {
    func reading(latitude: Double, longitude: Double) async throws -> WeatherReading {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let weather = try await WeatherService.shared.weather(for: location)
        let attribution = try await WeatherService.shared.attribution
        let today = weather.dailyForecast.forecast.first
        return WeatherReading(
            temperatureCelsius: weather.currentWeather.temperature.converted(to: .celsius).value,
            apparentCelsius: weather.currentWeather.apparentTemperature.converted(to: .celsius).value,
            condition: weather.currentWeather.condition.description,
            humidity: weather.currentWeather.humidity,
            windKilometresPerHour: weather.currentWeather.wind.speed
                .converted(to: .kilometersPerHour).value,
            highCelsius: today?.highTemperature.converted(to: .celsius).value,
            lowCelsius: today?.lowTemperature.converted(to: .celsius).value,
            attribution: .init(legalPageURL: attribution.legalPageURL, combinedMarkLightURL: attribution.combinedMarkLightURL, combinedMarkDarkURL: attribution.combinedMarkDarkURL))
    }
}

extension ForegroundWeatherService {
    convenience init(recordCard: @escaping @MainActor @Sendable (WeatherCard) async throws -> Void) { self.init(source: SystemWeatherSource(), recordCard: recordCard) }
}
#endif
