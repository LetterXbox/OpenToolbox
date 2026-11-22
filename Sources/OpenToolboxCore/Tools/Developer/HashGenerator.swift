import CryptoKit
import Foundation

public enum HashAlgorithm: String, CaseIterable, Codable, Sendable, Identifiable {
    case md5
    case sha1
    case sha256
    case sha384
    case sha512

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        case .sha384: "SHA-384"
        case .sha512: "SHA-512"
        }
    }

    /// MD5 and SHA-1 are fine for checksums but not for security.
    public var isCryptographicallyBroken: Bool { self == .md5 || self == .sha1 }
}

/// Computes message digests with CryptoKit.
public enum HashGenerator {
    public static func hash(_ data: Data, algorithm: HashAlgorithm) -> String {
        var hasher = StreamingHasher(algorithm)
        hasher.update(data)
        return hasher.finalize()
    }

    public static func hash(_ text: String, algorithm: HashAlgorithm) -> String {
        hash(Data(text.utf8), algorithm: algorithm)
    }

    /// Hashes a file in chunks so large files do not load into memory.
    public static func hashFile(
        at url: URL,
        algorithms: [HashAlgorithm],
        chunkSize: Int = 1 << 20
    ) throws -> [HashAlgorithm: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hashers = algorithms.map(StreamingHasher.init)
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            for index in hashers.indices {
                hashers[index].update(chunk)
            }
        }
        var result: [HashAlgorithm: String] = [:]
        for (algorithm, hasher) in zip(algorithms, hashers) {
            result[algorithm] = hasher.finalize()
        }
        return result
    }

    public static func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        try hashFile(at: url, algorithms: [algorithm])[algorithm] ?? ""
    }

    /// Compares a digest with user input, ignoring case, whitespace, and `:` separators.
    public static func matches(_ digest: String, expected: String) -> Bool {
        let normalized = expected.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        return !normalized.isEmpty && normalized == digest.lowercased()
    }
}

private enum StreamingHasher {
    case md5(Insecure.MD5)
    case sha1(Insecure.SHA1)
    case sha256(SHA256)
    case sha384(SHA384)
    case sha512(SHA512)

    init(_ algorithm: HashAlgorithm) {
        switch algorithm {
        case .md5: self = .md5(Insecure.MD5())
        case .sha1: self = .sha1(Insecure.SHA1())
        case .sha256: self = .sha256(SHA256())
        case .sha384: self = .sha384(SHA384())
        case .sha512: self = .sha512(SHA512())
        }
    }

    mutating func update(_ data: Data) {
        switch self {
        case .md5(var hasher):
            hasher.update(data: data)
            self = .md5(hasher)
        case .sha1(var hasher):
            hasher.update(data: data)
            self = .sha1(hasher)
        case .sha256(var hasher):
            hasher.update(data: data)
            self = .sha256(hasher)
        case .sha384(var hasher):
            hasher.update(data: data)
            self = .sha384(hasher)
        case .sha512(var hasher):
            hasher.update(data: data)
            self = .sha512(hasher)
        }
    }

    func finalize() -> String {
        switch self {
        case .md5(let hasher): ByteEncoding.hexEncode(Data(hasher.finalize()))
        case .sha1(let hasher): ByteEncoding.hexEncode(Data(hasher.finalize()))
        case .sha256(let hasher): ByteEncoding.hexEncode(Data(hasher.finalize()))
        case .sha384(let hasher): ByteEncoding.hexEncode(Data(hasher.finalize()))
        case .sha512(let hasher): ByteEncoding.hexEncode(Data(hasher.finalize()))
        }
    }
}
