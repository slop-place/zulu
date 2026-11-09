import Foundation

/// Which APNs gateway issued this install's device token. The signing profile decides
/// that, not the build configuration: a Release build run from Xcode still gets a
/// sandbox token.
enum APNsEnvironment: String {
    case sandbox
    case production

    private static let profileKey = "aps-environment"
    private static let developmentProfileValue = "development"
    private static let plistStart = Data("<?xml".utf8)
    private static let plistEnd = Data("</plist>".utf8)

    static let current: APNsEnvironment = {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        // App Store and TestFlight installs carry no embedded profile.
        guard let entitlements = embeddedProfileEntitlements(),
              let value = entitlements[profileKey] as? String
        else { return .production }
        return value == developmentProfileValue ? .sandbox : .production
        #endif
    }()

    /// The profile is a signed CMS envelope with the plist stored as plain text inside.
    private static func embeddedProfileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: plistStart),
              let end = data.range(of: plistEnd, in: start.lowerBound..<data.endIndex)
        else { return nil }

        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let profile = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return profile?["Entitlements"] as? [String: Any]
    }
}
