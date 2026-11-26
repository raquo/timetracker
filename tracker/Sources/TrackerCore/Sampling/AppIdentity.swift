import Foundation

/// `tracker_app.identifier_type`: what `identifier` holds. Stored as its raw value.
enum AppIdentifierType: Int64 {
    case bundleId = 0
    /// For processes without a bundle ID.
    case executablePath = 1
}

/// An app as the user thinks of it, regardless of where it's installed: `tracker_app` minus
/// `app_path`. The bundle ID, else the full executable path (never a bare name).
struct AppIdentity: Hashable {
    let type: AppIdentifierType
    let identifier: String

    init(type: AppIdentifierType, identifier: String) {
        self.type = type
        self.identifier = identifier
    }

    /// nil when there's neither a bundle ID nor an executable path.
    init?(bundleId: String?, executablePath: String?) {
        if let bundleId, !bundleId.isEmpty {
            self.init(type: .bundleId, identifier: bundleId)
        }
        else if let executablePath, !executablePath.isEmpty {
            self.init(type: .executablePath, identifier: executablePath)
        }
        else {
            return nil
        }
    }
}
