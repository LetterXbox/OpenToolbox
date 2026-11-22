import CoreWLAN
import Foundation
import Security

public enum WiFiPasswordError: Error, Equatable, LocalizedError {
    case emptyName
    case notFound(String)
    case denied
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyName: coreLocalized("Enter the Wi-Fi network's name.")
        case .notFound(let name): coreLocalized("This Mac has no saved password for “\(name)”.")
        case .denied: coreLocalized("macOS didn't allow access to the password.")
        case .failed(let status): coreLocalized("The password could not be read (error \(status)).")
        }
    }
}

public enum WiFiSecurity: String, CaseIterable, Sendable, Identifiable {
    case wpa
    case wep
    case open

    public var id: String { rawValue }
}

/// Reads saved Wi-Fi passwords and builds the QR code text phones use to join a network.
public enum WiFiPassword {
    /// The text of a Wi-Fi QR code: `WIFI:T:WPA;S:name;P:password;;`.
    public static func qrPayload(ssid: String, password: String, security: WiFiSecurity, hidden: Bool = false)
        -> String
    {
        var fields: [String] = []
        switch security {
        case .wpa: fields.append("T:WPA")
        case .wep: fields.append("T:WEP")
        case .open: fields.append("T:nopass")
        }
        fields.append("S:\(escape(ssid))")
        if security != .open { fields.append("P:\(escape(password))") }
        if hidden { fields.append("H:true") }
        return "WIFI:" + fields.map { $0 + ";" }.joined() + ";"
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\;,:\"".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The network this Mac is joined to. macOS hides it unless OpenToolbox may use Location Services.
    public static func currentNetworkName() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// Looks up a saved password in the System keychain. macOS asks for an administrator's
    /// name and password first, so call this off the main thread.
    public static func savedPassword(for ssid: String) throws -> String {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WiFiPasswordError.emptyName }
        var password: NSString?
        let status = CWKeychainFindWiFiPassword(.system, Data(name.utf8), &password)
        switch status {
        case errSecSuccess:
            guard let password else { throw WiFiPasswordError.notFound(name) }
            return password as String
        case errSecItemNotFound: throw WiFiPasswordError.notFound(name)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: throw WiFiPasswordError.denied
        default: throw WiFiPasswordError.failed(status)
        }
    }
}
