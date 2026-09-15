import Contacts
import CoreLocation
import EventKit
import MediaPlayer
import OperatorCore
import Photos

/// Where iOS stands on the permission a connector also needs. Operator's own
/// grant and this are separate gates; the Permissions page shows both so a
/// row that is allowed in Operator but denied by iOS explains itself.
enum SystemPermissionState: Equatable {
    case notDetermined, allowed, limited, denied

    var label: String {
        switch self {
        case .notDetermined: "iOS will ask on first use"
        case .allowed: "Allowed in iOS"
        case .limited: "Limited in iOS"
        case .denied: "Denied in iOS Settings"
        }
    }
}

enum SystemPermissionStatus {
    static func current(_ permission: SystemPermission) -> SystemPermissionState {
        switch permission {
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: .allowed
            case .writeOnly: .limited
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: .allowed
            case .writeOnly: .limited
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: .allowed
            case .limited: .limited
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: .allowed
            case .limited: .limited
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .music:
            switch MPMediaLibrary.authorizationStatus() {
            case .authorized: .allowed
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: .allowed
            case .notDetermined: .notDetermined
            default: .denied
            }
        }
    }
}
