import Foundation
import IOKit
import IOKit.pwr_mgt

public enum KeepAwakeDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = 900
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400
    case indefinitely = 0

    public var id: Int { rawValue }
    public var duration: Duration? { self == .indefinitely ? nil : .seconds(rawValue) }

    public var title: String {
        switch self {
        case .fifteenMinutes: coreLocalized("15 minutes")
        case .oneHour: coreLocalized("1 hour")
        case .twoHours: coreLocalized("2 hours")
        case .fourHours: coreLocalized("4 hours")
        case .indefinitely: coreLocalized("Indefinitely")
        }
    }
}

/// Holds one idle-sleep assertion for the lifetime of the handle.
public final class PowerAssertion {
    private let id: IOPMAssertionID

    public init(keepingDisplayAwake: Bool) throws {
        // A display assertion also prevents idle system sleep.
        let type = keepingDisplayAwake ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        var id: IOPMAssertionID = 0
        let reason = coreLocalized("OpenToolbox Keep Awake")
        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)
        let result = IOPMAssertionCreateWithName(type as CFString, level, reason as CFString, &id)
        guard result == kIOReturnSuccess else { throw AssertionError(status: result) }
        self.id = id
    }

    deinit {
        IOPMAssertionRelease(id)
    }

    private struct AssertionError: LocalizedError {
        let status: IOReturn

        var errorDescription: String? {
            coreLocalized("Could not prevent idle sleep (IOKit error \(status)).")
        }
    }
}
