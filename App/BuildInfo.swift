import Foundation

/// Version and build metadata read from the app's Info.plist.
/// `TCBuildDate` is filled at build time via Info.plist preprocessing.
struct BuildInfo: Sendable {
    let displayName: String
    let version: String
    let build: String
    /// UTC time the app target was built.
    let buildDate: Date?
    let isDevelopment: Bool

    static let current = BuildInfo(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? "TitleCut"
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String ?? "?"
        if let stamp = info["TCBuildDate"] as? String {
            buildDate = try? Date(stamp, strategy: .iso8601)
        } else {
            buildDate = nil
        }
        #if DEBUG
        isDevelopment = true
        #else
        isDevelopment = false
        #endif
    }

    var badge: String { isDevelopment ? "DEV" : "PROD" }
}
