import Darwin
import Foundation
import Testing

@testable import OpenToolboxCore

@Suite("Mac utilities")
struct MacUtilityTests {
    @Test func batterySeparatesNormalizedChargeFromPhysicalCapacity() throws {
        let battery = try #require(BatteryHealth.parse([
            "BatteryInstalled": true, "CycleCount": 127, "DesignCapacity": 5_000,
            "MaxCapacity": 100, "CurrentCapacity": 62, "AppleRawCurrentCapacity": 2_420,
            "NominalChargeCapacity": 4_500, "IsCharging": false, "ExternalConnected": true,
            "BatteryData": ["Temperature": 3_125], "Voltage": 12_350,
            "BatteryHealthCondition": "Normal",
        ]))
        #expect(battery.cycleCount == 127)
        #expect(battery.healthPercent == 90)
        #expect(battery.chargePercent == 62)
        #expect(battery.currentCapacityMAh == 2_420)
        #expect(battery.isCharging == false)
        #expect(battery.isExternalPowerConnected == true)
        #expect(battery.temperatureCelsius == 31.25)
        #expect(battery.voltageMillivolts == 12_350)
        #expect(battery.condition == "Normal")
    }

    @Test func batteryHandlesLegacyCapacityAndAbsentHardware() throws {
        let legacy = try #require(BatteryHealth.parse([
            "MaxCapacity": 3_200, "CurrentCapacity": 800, "DesignCapacity": 4_000,
        ]))
        #expect(legacy.healthPercent == 80)
        #expect(legacy.chargePercent == 25)
        #expect(legacy.currentCapacityMAh == 800)
        let partial = try #require(BatteryHealth.parse(["MaxCapacity": 100, "DesignCapacity": 5_000]))
        #expect(partial.healthPercent == nil)
        #expect(BatteryHealth.parse(["BatteryInstalled": false]) == nil)
        #expect(BatteryHealth.parse([:]) == nil)
    }

    @Test func networkQualityParsesThroughputAndPartialJSON() throws {
        let full = try NetworkSpeedTest.parse(Data("""
            {"dl_throughput":278482080,"ul_throughput":52300000,"responsiveness":421,
             "base_rtt":20.5,"interface_name":"en0","unused":[1,2]}
            """.utf8))
        #expect(full.downloadBitsPerSecond == 278_482_080)
        #expect(full.uploadBitsPerSecond == 52_300_000)
        #expect(full.responsivenessRPM == 421)
        #expect(full.baseRTTMilliseconds == 20.5)
        #expect(full.interfaceName == "en0")

        let partial = try NetworkSpeedTest.parse(Data(
            #"{"ul_throughput":"12000000","base_rtt":false,"interface_name":null}"#.utf8
        ))
        #expect(partial.uploadBitsPerSecond == 12_000_000)
        #expect(partial.downloadBitsPerSecond == nil)
        #expect(partial.responsivenessRPM == nil)
        #expect(partial.baseRTTMilliseconds == nil)
        #expect(partial.interfaceName == nil)
        #expect(throws: DecodingError.self) { try NetworkSpeedTest.parse(Data("[]".utf8)) }
    }

    @Test func ejectCandidatesExcludeStartupInternalNetworkAndUnknownVolumes() {
        func volume(_ path: String, ejectable: Bool? = nil, removable: Bool? = nil,
                    internalBus: Bool? = nil, root: Bool? = false, local: Bool? = true) -> MountedVolume {
            MountedVolume(
                url: URL(fileURLWithPath: path), name: path, capacityBytes: nil, uuid: nil,
                isEjectable: ejectable, isRemovable: removable, isInternal: internalBus,
                isRootFileSystem: root, isLocal: local
            )
        }

        let external = volume("/Volumes/USB", ejectable: false, removable: false, internalBus: false)
        let removable = volume("/Volumes/SD", removable: true)
        let image = volume("/Volumes/Image", ejectable: true)
        let candidates = MountedVolume.ejectCandidates(from: [
            volume("/", ejectable: true, root: true),
            volume("/Volumes/Internal", ejectable: true, internalBus: true),
            volume("/Volumes/Network", ejectable: true, internalBus: false, local: false),
            volume("/Volumes/Unknown"), volume("/Volumes/UnknownRoot", ejectable: true, root: nil),
            external, removable, image,
        ])
        #expect(candidates.map(\.url) == [external.url, removable.url, image.url])
    }

    @Test func quarantineParsesAndRemovesAnAttributeOnATemporaryFile() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: "sample")
            try Data("original contents".utf8).write(to: file)
            let before = try QuarantineAttribute.read(at: file)
            #expect(before == .absent)

            let value = Data("0083;65a0bc00;Test Agent;80DEABBB-7518-4BA4-AB89-1CDFE3AB2F7E".utf8)
            let writeResult: Int32 = file.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return value.withUnsafeBytes { buffer in
                    setxattr(path, "com.apple.quarantine", buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
                }
            }
            try #require(writeResult == 0)
            guard case .present(let record) = try QuarantineAttribute.read(at: file) else {
                Issue.record("Expected a quarantine attribute")
                return
            }
            #expect(record?.flags == 0x0083)
            #expect(record?.date == Date(timeIntervalSince1970: 1_705_032_704))
            #expect(record?.agentName == "Test Agent")
            #expect(record?.eventID == "80DEABBB-7518-4BA4-AB89-1CDFE3AB2F7E")

            try QuarantineAttribute.remove(at: file)
            try QuarantineAttribute.remove(at: file)
            #expect(try QuarantineAttribute.read(at: file) == .absent)
            #expect(try Data(contentsOf: file) == Data("original contents".utf8))
        }
    }

    @Test func quarantineAcceptsEmptyOptionalFieldsAndRejectsInvalidFlags() {
        let partial = QuarantineAttribute.parse("0081;;Agent;")
        #expect(partial?.agentName == "Agent")
        #expect(partial?.date == nil)
        #expect(partial?.eventID == nil)
        #expect(QuarantineAttribute.parse("invalid;bad;Agent") == nil)
    }

    @Test func hiddenSettingsConvertPreferenceValuesAndBuildTypedArguments() throws {
        let extensions = try #require(HiddenSetting.all.first { $0.key == "AppleShowAllExtensions" })
        #expect(extensions.kind.decode(NSNumber(value: true)) == .boolean(true))
        #expect(extensions.defaultsArguments(for: .boolean(true)) ==
                ["write", "NSGlobalDomain", "AppleShowAllExtensions", "-bool", "true"])
        #expect(extensions.defaultsArguments(for: nil) ==
                ["delete", "NSGlobalDomain", "AppleShowAllExtensions"])
        #expect(extensions.defaultsArguments(for: .seconds(1)) == nil)

        let dockDelay = try #require(HiddenSetting.all.first { $0.key == "autohide-delay" })
        #expect(dockDelay.kind.decode(NSNumber(value: false)) == nil)
        #expect(dockDelay.kind.decode(NSNumber(value: 0.25)) == .seconds(0.25))
        #expect(dockDelay.defaultsArguments(for: .seconds(0.25)) ==
                ["write", "com.apple.dock", "autohide-delay", "-float", "0.25"])
        #expect(dockDelay.defaultsArguments(for: .seconds(.infinity)) == nil)
        #expect(dockDelay.defaultsArguments(for: .seconds(-1)) == nil)

        let location = try #require(HiddenSetting.all.first { $0.key == "location" })
        #expect(location.defaultsArguments(for: .text("/Users/example/Screen Shots")) ==
                ["write", "com.apple.screencapture", "location", "-string", "/Users/example/Screen Shots"])
        #expect(location.defaultsArguments(for: .text("relative")) == nil)

        let format = try #require(HiddenSetting.all.first { $0.key == "type" })
        #expect(format.kind.decode("jpg") == .text("jpg"))
        #expect(format.defaultsArguments(for: .text("unsupported")) == nil)
    }
}
