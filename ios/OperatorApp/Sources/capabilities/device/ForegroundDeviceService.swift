import Foundation
import Network
import OperatorCore
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// What the phone can say about itself without asking anyone's permission,
// and nothing more. Battery, power mode, whether there is a network, and how
// the owner's dates and times should be written.
//
// Deliberately absent: any identifier. No device id, no name, no advertising
// id, no model. Those identify a person across contexts and none of them help
// an agent decide anything, which is the only reason a field is here at all.
// The test pins that absence.

struct DeviceStatus: Sendable, Equatable {
    let batteryLevel: Double?
    let charging: Bool?
    let lowPowerMode: Bool
    let networkAvailable: Bool
    let networkIsExpensive: Bool
    let localeIdentifier: String
    let timeZoneIdentifier: String
}

@MainActor
protocol DeviceStatusSource: AnyObject {
    func status() -> DeviceStatus
}

@MainActor
final class ForegroundDeviceService: GatewayNodeCommandHandler {
    private struct Payload: Encodable {
        let batteryLevel: Double?
        let charging: Bool?
        let lowPowerMode: Bool
        let online: Bool
        let meteredConnection: Bool
        let locale: String
        let timeZone: String
    }

    private let source: any DeviceStatusSource
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-device")

    init(source: any DeviceStatusSource) { self.source = source }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "device.status" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard Self.acceptsEmptyObject(paramsJSON) else {
            self.logger.info("[device] refused branch=invalid_params")
            return .failure(code: "INVALID_REQUEST", message: "device.status does not accept parameters")
        }
        let status = self.source.status()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(
            batteryLevel: status.batteryLevel,
            charging: status.charging,
            lowPowerMode: status.lowPowerMode,
            online: status.networkAvailable,
            meteredConnection: status.networkIsExpensive,
            locale: status.localeIdentifier,
            timeZone: status.timeZoneIdentifier)),
            let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[device] failed branch=encode")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not read the device status")
        }
        self.logger.info("[device] returned online=\(status.networkAvailable) lowPower=\(status.lowPowerMode)")
        return .success(payloadJSON: payloadJSON)
    }

    static func acceptsEmptyObject(_ paramsJSON: String?) -> Bool {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any]
        else { return false }
        return object.isEmpty
    }
}

#if canImport(UIKit)
@MainActor
final class SystemDeviceStatusSource: DeviceStatusSource {
    private let monitor = NWPathMonitor()

    init() { self.monitor.start(queue: DispatchQueue(label: "app.operator.ios.device-path")) }
    deinit { self.monitor.cancel() }

    func status() -> DeviceStatus {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let path = self.monitor.currentPath
        return DeviceStatus(
            // UIKit reports -1 when the level is genuinely unknown, which is
            // not the same as an empty battery and must not be sent as one.
            batteryLevel: level < 0 ? nil : Double((level * 100).rounded()) / 100,
            charging: state == .unknown ? nil : (state == .charging || state == .full),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            networkAvailable: path.status == .satisfied,
            networkIsExpensive: path.isExpensive,
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier)
    }
}

extension ForegroundDeviceService {
    convenience init() { self.init(source: SystemDeviceStatusSource()) }
}
#endif
