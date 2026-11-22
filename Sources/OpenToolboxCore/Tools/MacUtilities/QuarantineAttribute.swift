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

public struct QuarantineInspection: Sendable {
    public let status: QuarantineStatus
    fileprivate let identity: FileIdentity
    fileprivate let value: Data?
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
        try inspect(at: url).status
    }

    public static func inspect(at url: URL) throws -> QuarantineInspection {
        try withOpenFile(at: url) { fd, identity in
            let value = try readValue(from: fd, at: url)
            let status = value.map { data in
                QuarantineStatus.present(String(data: data, encoding: .utf8).flatMap(parse))
            } ?? .absent
            return QuarantineInspection(status: status, identity: identity, value: value)
        }
    }

    public static func remove(at url: URL, matching inspection: QuarantineInspection) throws {
        try withOpenFile(at: url) { fd, identity in
            guard let expected = inspection.value, identity == inspection.identity,
                  try readValue(from: fd, at: url) == expected else {
                throw FileToolError.changed(url)
            }
            if fremovexattr(fd, name, 0) != 0 {
                let error = errno
                if error == ENOATTR { throw FileToolError.changed(url) }
                throw posixError(error, url: url)
            }
        }
    }

    private static func withOpenFile<T>(
        at url: URL, _ operation: (Int32, FileIdentity) throws -> T
    ) throws -> T {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw posixError(EINVAL, url: url) }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw posixError(errno, url: url) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw posixError(errno, url: url) }
            return try operation(fd, FileIdentity(info))
        }
    }

    private static func readValue(from fd: Int32, at url: URL) throws -> Data? {
        let length = fgetxattr(fd, name, nil, 0, 0, 0)
        if length < 0 {
            let error = errno
            if error == ENOATTR { return nil }
            throw posixError(error, url: url)
        }
        var data = Data(count: max(1, length))
        let count = data.withUnsafeMutableBytes {
            fgetxattr(fd, name, $0.baseAddress, $0.count, 0, 0)
        }
        if count < 0 {
            let error = errno
            if error == ENOATTR { return nil }
            throw posixError(error, url: url)
        }
        data.count = count
        return data
    }

    private static func posixError(_ code: Int32, url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
