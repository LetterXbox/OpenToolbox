import Foundation

public enum JWTDecodeError: Error, Equatable, LocalizedError {
    case empty
    case encryptedToken
    case wrongSegmentCount(Int)
    case invalidBase64(segment: String)
    case invalidJSON(segment: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            coreLocalized("Paste a JSON Web Token to decode it.")
        case .encryptedToken:
            coreLocalized("This is an encrypted token (JWE). It cannot be read without the decryption key.")
        case .wrongSegmentCount(let count):
            coreLocalized("A JWT has three dot-separated parts; this input has \(count).")
        case .invalidBase64(let segment):
            coreLocalized("The \(segment) is not valid Base64URL.")
        case .invalidJSON(let segment, let detail):
            coreLocalized("The \(segment) is not valid JSON. \(detail)")
        }
    }
}

/// A registered time claim (`exp`, `nbf`, `iat`) decoded to a date.
public struct JWTTimeClaim: Equatable, Sendable, Identifiable {
    public var name: String
    public var date: Date
    public var id: String { name }
}

public struct DecodedJWT: Equatable, Sendable {
    public var header: JSONValue
    public var payload: JSONValue
    /// The raw Base64URL signature segment (not verified).
    public var signature: String

    public var algorithm: String? { header["alg"]?.stringValue }

    public var prettyHeader: String { JSONFormatter.serialize(header, indent: .twoSpaces) }
    public var prettyPayload: String { JSONFormatter.serialize(payload, indent: .twoSpaces) }

    public var timeClaims: [JWTTimeClaim] {
        ["iat", "nbf", "exp"].compactMap { name in
            payload[name]?.doubleValue.map { JWTTimeClaim(name: name, date: Date(timeIntervalSince1970: $0)) }
        }
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let exp = payload["exp"]?.doubleValue else { return false }
        return now.timeIntervalSince1970 >= exp
    }

    public func isNotYetValid(at now: Date = Date()) -> Bool {
        guard let nbf = payload["nbf"]?.doubleValue else { return false }
        return now.timeIntervalSince1970 < nbf
    }
}

/// Decodes JWS compact tokens for inspection. Signatures are never verified.
public enum JWTDecoder {
    public static func decode(_ input: String) throws -> DecodedJWT {
        var token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard !token.isEmpty else { throw JWTDecodeError.empty }

        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if segments.count == 5 { throw JWTDecodeError.encryptedToken }
        guard segments.count == 3 else { throw JWTDecodeError.wrongSegmentCount(segments.count) }

        let headerName = coreLocalized("header")
        let payloadName = coreLocalized("payload")
        return DecodedJWT(
            header: try decodeSegment(segments[0], name: headerName),
            payload: try decodeSegment(segments[1], name: payloadName),
            signature: segments[2]
        )
    }

    private static func decodeSegment(_ segment: String, name: String) throws -> JSONValue {
        guard let data = try? ByteEncoding.base64Decode(segment), !segment.isEmpty else {
            throw JWTDecodeError.invalidBase64(segment: name)
        }
        do {
            return try JSONParser.parse(String(decoding: data, as: UTF8.self))
        } catch {
            throw JWTDecodeError.invalidJSON(segment: name, detail: error.localizedDescription)
        }
    }
}
