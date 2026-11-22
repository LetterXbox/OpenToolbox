import Darwin
import Foundation

public struct QuarantineRecord: Equatable, Sendable {
    public let flags: UInt32
    public let date: Date?
    public let agentName: String?
    public let eventID: String?
}

public enum QuarantineStatus: Equatable, Sendable {
    case absent
    case present(QuarantineRecord?)
}

public enum QuarantineAttribute {
    private static let name = "com.apple.quarantine"

    public static func parse(_ text: String) -> QuarantineRecord? {
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard (3...4).contains(fields.count), let flags = UInt32(fields[0], radix: 16) else { return nil }
        let date = UInt64(fields[1], radix: 16).map { Date(timeIntervalSince1970: Double($0)) }
        return QuarantineRecord(
            flags: flags,
            date: date,
            agentName: fields[2].isEmpty ? nil : String(fields[2]),
            eventID: fields.count == 4 && !fields[3].isEmpty ? String(fields[3]) : nil
        )
    }

    public static func read(at url: URL) throws -> QuarantineStatus {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw posixError(EINVAL, url: url) }
            // Normal records are short. An oversized value can still be identified and removed.
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let size = bytes.withUnsafeMutableBytes {
                getxattr(path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            if size < 0 {
                let error = errno
                if error == ENOATTR { return .absent }
                if error == ERANGE { return .present(nil) }
                throw posixError(error, url: url)
            }
            let text = String(bytes: bytes.prefix(size), encoding: .utf8)
            return .present(text.flatMap(parse))
        }
    }

    public static func remove(at url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw posixError(EINVAL, url: url) }
            if removexattr(path, name, XATTR_NOFOLLOW) != 0 {
                let error = errno
                if error != ENOATTR { throw posixError(error, url: url) }
            }
        }
    }

    private static func posixError(_ code: Int32, url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
