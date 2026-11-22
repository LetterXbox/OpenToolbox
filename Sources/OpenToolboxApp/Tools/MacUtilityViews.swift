import AppKit
import Observation
import OpenToolboxCore
import SwiftUI

@MainActor
@Observable
private final class KeepAwakeController {
    static let shared = KeepAwakeController()

    private var assertion: PowerAssertion?
    private var timer: Task<Void, Never>?
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var isKeepingDisplayAwake = false
    var isActive: Bool { assertion != nil }
    private(set) var error: String?

    private init() {
        // This controller lives for the entire app session, including when another tool is open.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func start(for duration: KeepAwakeDuration, keepingDisplayAwake: Bool) {
        guard !isActive else { return }
        error = nil
        do {
            assertion = try PowerAssertion(keepingDisplayAwake: keepingDisplayAwake)
            isKeepingDisplayAwake = keepingDisplayAwake
            if let interval = duration.duration {
                let clock = ContinuousClock()
                let end = clock.now.advanced(by: interval)
                deadline = end
                timer = Task { [weak self] in
                    do {
                        try await clock.sleep(until: end)
                        try Task.checkCancellation()
                        self?.stop()
                    } catch is CancellationError {
                        // A stop or app termination already released the assertion.
                    } catch {
                        self?.stop()
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        assertion = nil
        deadline = nil
        isKeepingDisplayAwake = false
    }
}

struct KeepAwakeView: View {
    let tool: ToolDescriptor
    @State private var duration: KeepAwakeDuration = .oneHour
    @State private var keepDisplayAwake = false
    private let controller = KeepAwakeController.shared

    var body: some View {
        ToolPage(tool: tool) {
            Pane(L("Idle sleep"), accessory: {
                if controller.isActive {
                    Badge(text: L("Active"), tint: .green)
                }
            }) {
                HStack(spacing: 16) {
                    Picker(L("Duration"), selection: $duration) {
                        ForEach(KeepAwakeDuration.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .fixedSize()
                    Toggle(L("Keep the display awake"), isOn: $keepDisplayAwake)
                }
                .disabled(controller.isActive)

                if controller.isActive {
                    Label(
                        controller.isKeepingDisplayAwake ? L("Mac and display are kept awake") : L("Mac is kept awake"),
                        systemImage: "cup.and.saucer"
                    )
                    if let deadline = controller.deadline {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let remaining = max(Duration.zero, ContinuousClock().now.duration(to: deadline))
                            let time = remaining.formatted(.time(pattern: .hourMinuteSecond))
                            Text(L("Time remaining: \(time)")).monospacedDigit()
                        }
                    } else {
                        Text(L("Until you stop or quit OpenToolbox.")).foregroundStyle(.secondary)
                    }
                    Button(L("Stop Keeping Awake")) { controller.stop() }
                } else {
                    Button(L("Keep Awake")) {
                        controller.start(for: duration, keepingDisplayAwake: keepDisplayAwake)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let error = controller.error {
                ErrorMessage(text: error)
            }
        }
    }
}

struct BatteryHealthView: View {
    let tool: ToolDescriptor
    @State private var battery: BatteryHealth?
    @State private var error: String?

    var body: some View {
        ToolPage(tool: tool) {
            Pane(L("Battery information"), accessory: {
                Button(L("Refresh"), systemImage: "arrow.clockwise") { refresh() }
            }) {
                if let error {
                    ErrorMessage(text: error)
                } else if let battery {
                    if let charge = battery.chargePercent {
                        ProgressView(value: charge, total: 100) {
                            Text(L("Current charge"))
                        } currentValueLabel: {
                            Text(percent(charge))
                        }
                    }
                    MacUtilityMetrics(rows: [
                        (L("Battery health"), battery.healthPercent.map(percent)),
                        (L("Condition"), battery.condition),
                        (L("Cycle count"), battery.cycleCount?.formatted()),
                        (L("Design capacity"), battery.designCapacityMAh.map(capacity)),
                        (L("Maximum capacity"), battery.maxCapacityMAh.map(capacity)),
                        (L("Current capacity"), battery.currentCapacityMAh.map(capacity)),
                        (L("Charging"), battery.isCharging.map(yesNo)),
                        (L("External power connected"), battery.isExternalPowerConnected.map(yesNo)),
                        (L("Temperature"), battery.temperatureCelsius.map { L("\(decimal($0)) °C") }),
                        (L("Voltage"), battery.voltageMillivolts.map { L("\(decimal(Double($0) / 1_000)) V") }),
                    ])
                } else {
                    Text(L("No built-in battery was found on this Mac.")).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        do {
            battery = try BatteryHealth.read()
            error = nil
        } catch {
            battery = nil
            self.error = error.localizedDescription
        }
    }

    private func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }

    private func capacity(_ value: Int) -> String { L("\(value.formatted()) mAh") }

    private func yesNo(_ value: Bool) -> String { value ? L("Yes") : L("No") }
}

struct NetworkSpeedTestView: View {
    let tool: ToolDescriptor
    @State private var test: Task<Void, Never>?
    @State private var result: NetworkSpeedResult?
    @State private var error: String?
    @State private var wasCancelled = false

    var body: some View {
        ToolPage(tool: tool) {
            Text(L("Uses Apple’s networkQuality tool and contacts Apple’s test servers."))
                .foregroundStyle(.secondary)
            HStack {
                Button(L("Start Test")) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(test != nil)
                if let test {
                    Button(L("Cancel")) { test.cancel() }.disabled(test.isCancelled)
                    ProgressView().controlSize(.small).accessibilityLabel(L("Testing network speed"))
                }
            }
            if let error {
                ErrorMessage(text: error)
            } else if wasCancelled {
                Text(L("Test cancelled.")).foregroundStyle(.secondary)
            }
            if let result {
                let rows = resultRows(result)
                Pane(L("Results"), accessory: {
                    CopyButton(text: rows.compactMap { label, value in
                        value.map { L("\(label): \($0)") }
                    }.joined(separator: "\n"))
                }) {
                    MacUtilityMetrics(rows: rows)
                }
            }
        }
        .onDisappear { test?.cancel() }
        .reportsActivity(test != nil)
    }

    private func start() {
        guard test == nil else { return }
        result = nil
        error = nil
        wasCancelled = false
        test = Task {
            defer { test = nil }
            do {
                result = try await NetworkSpeedTest.run()
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func resultRows(_ result: NetworkSpeedResult) -> [(String, String?)] {
        [
            (L("Download"), result.downloadBitsPerSecond.map { L("\(decimal($0 / 1_000_000)) Mbps") }),
            (L("Upload"), result.uploadBitsPerSecond.map { L("\(decimal($0 / 1_000_000)) Mbps") }),
            (L("Responsiveness"), result.responsivenessRPM.map { L("\(decimal($0)) RPM") }),
            (L("Idle latency"), result.baseRTTMilliseconds.map { L("\(decimal($0)) ms") }),
            (L("Network interface"), result.interfaceName),
        ]
    }
}

struct MacUtilityMetrics: View {
    let rows: [(String, String?)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                let (label, value) = rows[index]
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    Text(value ?? L("Unavailable")).textSelection(.enabled)
                }
            }
        }
    }
}

private func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}
