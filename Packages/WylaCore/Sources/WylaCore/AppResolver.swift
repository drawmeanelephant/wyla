import AppKit
import Security

/// What macOS knows about an app, beyond the bundle ID and name in the system log.
public struct AppInfo: Sendable, Equatable {
    public let name: String?
    public let path: String
    /// The signing Team ID, or nil for Apple's own apps and unsigned or ad-hoc signed code.
    public let teamID: String?

    public init(name: String?, path: String, teamID: String?) {
        self.name = name
        self.path = path
        self.teamID = teamID
    }
}

public enum AppResolver {
    /// Looks up an installed app by bundle ID. Returns nil for executable names (command-line
    /// clients) and for apps that Launch Services doesn't know.
    public static func resolve(_ client: String) -> AppInfo? {
        guard !Attribution(sensor: .camera, client: client).isExecutableName,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client)
        else { return nil }
        let bundle = Bundle(url: url)
        let name = ["CFBundleDisplayName", "CFBundleName"].lazy.compactMap { bundle?.object(forInfoDictionaryKey: $0) as? String }.first
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return AppInfo(name: name, path: path, teamID: teamID(of: url))
    }

    private static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
