import CoreFoundation
import Foundation
import IOKit
import IOKit.ps

public struct BatteryHealth: Equatable, Sendable {
    public let cycleCount: Int?
    public let designCapacityMAh: Int?
    public let maxCapacityMAh: Int?
    public let currentCapacityMAh: Int?
    public let chargePercent: Double?
    public let isCharging: Bool?
    public let isExternalPowerConnected: Bool?
    public let temperatureCelsius: Double?
    public let voltageMillivolts: Int?
    public let condition: String?

    public var healthPercent: Double? {
        guard let maxCapacityMAh, let designCapacityMAh else { return nil }
        return Double(maxCapacityMAh) / Double(designCapacityMAh) * 100
    }

    public static func read() throws -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard status == kIOReturnSuccess,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            throw ReadError(status: status)
        }
        let snapshot = parse(dictionary)
        if let snapshot, snapshot.condition == nil, let condition = powerSourceCondition() {
            var supplemented = dictionary
            supplemented["BatteryHealth"] = condition
            return parse(supplemented)
        }
        return snapshot
    }

    /// Uses nominal or raw mAh capacities for health, including when MaxCapacity is normalized to 100.
    public static func parse(_ properties: [String: Any]) -> BatteryHealth? {
        guard !properties.isEmpty, properties["BatteryInstalled"] as? Bool != false else { return nil }
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        func positive(_ key: String) -> Int? {
            let value = properties[key] as? Int ?? batteryData[key] as? Int
            guard let value, value > 0 else { return nil }
            return value
        }
        let reportedMax = positive("MaxCapacity")
        let legacyMax = reportedMax.flatMap { $0 > 100 ? $0 : nil }
        let max = positive("NominalChargeCapacity") ?? positive("AppleRawMaxCapacity") ?? legacyMax
        let charge = (properties["CurrentCapacity"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        let rawCharge = (properties["AppleRawCurrentCapacity"] as? Int ?? batteryData["AppleRawCurrentCapacity"] as? Int)
            .flatMap { $0 >= 0 ? $0 : nil }
        let currentMAh = rawCharge ?? (legacyMax != nil ? charge : nil)
        let chargePercent: Double?
        if let charge, let reportedMax {
            chargePercent = min(100, Double(charge) / Double(reportedMax) * 100)
        } else if let currentMAh, let max {
            chargePercent = min(100, Double(currentMAh) / Double(max) * 100)
        } else {
            chargePercent = nil
        }
        let temperature = properties["Temperature"] as? Int ?? batteryData["Temperature"] as? Int
        return BatteryHealth(
            cycleCount: properties["CycleCount"] as? Int ?? batteryData["CycleCount"] as? Int,
            designCapacityMAh: positive("DesignCapacity"),
            maxCapacityMAh: max,
            currentCapacityMAh: currentMAh,
            chargePercent: chargePercent,
            isCharging: properties["IsCharging"] as? Bool,
            isExternalPowerConnected: properties["ExternalConnected"] as? Bool,
            temperatureCelsius: temperature.map { Double($0) / 100 },
            voltageMillivolts: positive("Voltage"),
            condition: properties["BatteryHealthCondition"] as? String
                ?? properties["BatteryHealth"] as? String
                ?? properties["Condition"] as? String
        )
    }

    private static func powerSourceCondition() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any], description["Type"] as? String == "InternalBattery" else { continue }
            return description["BatteryHealthCondition"] as? String ?? description["BatteryHealth"] as? String
        }
        return nil
    }

    private struct ReadError: LocalizedError {
        let status: IOReturn

        var errorDescription: String? {
            coreLocalized("Could not read battery information (IOKit error \(status)).")
        }
    }
}
