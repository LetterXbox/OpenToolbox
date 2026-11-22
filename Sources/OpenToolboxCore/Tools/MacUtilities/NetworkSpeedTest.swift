import Foundation

public struct NetworkSpeedResult: Decodable, Equatable, Sendable {
    public let downloadBitsPerSecond: Double?
    public let uploadBitsPerSecond: Double?
    public let responsivenessRPM: Double?
    public let baseRTTMilliseconds: Double?
    public let interfaceName: String?

    private enum CodingKeys: String, CodingKey {
        case download = "dl_throughput"
        case upload = "ul_throughput"
        case responsiveness
        case latency = "base_rtt"
        case interface = "interface_name"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? {
            let value = (try? values.decode(Double.self, forKey: key))
                ?? (try? values.decode(String.self, forKey: key)).flatMap { Double($0) }
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }

        downloadBitsPerSecond = number(.download)
        uploadBitsPerSecond = number(.upload)
        responsivenessRPM = number(.responsiveness)
        baseRTTMilliseconds = number(.latency)
        interfaceName = try? values.decode(String.self, forKey: .interface)
    }
}

public enum NetworkSpeedTest {
    public static func parse(_ json: Data) throws -> NetworkSpeedResult {
        try JSONDecoder().decode(NetworkSpeedResult.self, from: json)
    }

    @MainActor
    public static func run() async throws -> NetworkSpeedResult {
        let output = try await MacUtilityCommand.run("/usr/bin/networkQuality", arguments: ["-c"])
        return try parse(output)
    }
}
