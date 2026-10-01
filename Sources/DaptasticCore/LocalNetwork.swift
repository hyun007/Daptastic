import Foundation

/// macOS asks before an app may reach devices on the local network (a LAN IP, a `.local`
/// name, or a public name that split DNS resolves to a LAN address). Until the user answers
/// — or after they choose Don't Allow — connections fail at once as "offline" (-1009).
public enum LocalNetwork {
    /// Whether `error` is that block rather than a genuinely unreachable server. The only
    /// signal is the network path's description, so this is best effort.
    public static func isBlocked(_ error: Error) -> Bool {
        guard let error = error as? URLError, error.code == .notConnectedToInternet else { return false }
        return describe(error as NSError).localizedCaseInsensitiveContains("local network prohibited")
    }

    private static func describe(_ error: NSError) -> String {
        var text = error.userInfo.values.map { String(describing: $0) }.joined(separator: " ")
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { text += " " + describe(underlying) }
        return text
    }

    /// System Settings → Privacy & Security → Local Network.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
}
