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

    /// Time claims holding a usable NumericDate. Invalid ones are reported by ``validity(at:)``.
    public var timeClaims: [JWTTimeClaim] {
        ["iat", "nbf", "exp"].compactMap { name in
            numericDate(name).map { JWTTimeClaim(name: name, date: Date(timeIntervalSince1970: $0)) }
        }
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let exp = numericDate("exp") else { return false }
        return now.timeIntervalSince1970 >= exp
    }

    public func isNotYetValid(at now: Date = Date()) -> Bool {
        guard let nbf = numericDate("nbf") else { return false }
        return now.timeIntervalSince1970 < nbf
    }

    /// The token's validity window at `now`, judged from `exp` and `nbf` only (not the signature).
    public func validity(at now: Date = Date()) -> JWTValidity {
        let claims = ["exp", "nbf"].filter { payload[$0] != nil }
        if claims.contains(where: { numericDate($0) == nil }) { return .invalidTimeClaim }
        if isExpired(at: now) { return .expired }
        if isNotYetValid(at: now) { return .notYetValid }
        return claims.isEmpty ? .noTimeLimit : .valid
    }

    /// A claim's value when it is a JSON number inside the supported date range.
    func numericDate(_ name: String) -> Double? {
        guard let seconds = payload[name]?.doubleValue, TimestampConverter.isSupported(seconds) else { return nil }
        return seconds
    }
}

public enum JWTValidity: Equatable, Sendable {
    /// Neither `exp` nor `nbf` is present.
    case noTimeLimit
    /// `exp` or `nbf` is present but is not a usable number of seconds.
    case invalidTimeClaim
    case expired
    case notYetValid
    case valid
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
