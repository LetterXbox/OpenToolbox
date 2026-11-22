import AppKit
import CoreLocation
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Wi-Fi Password

/// Asks for Location Services, which macOS requires before it reveals Wi-Fi network names.
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        ![.notDetermined, .denied, .restricted].contains(manager.authorizationStatus)
    }

    var isDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    func request() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.resumeWaiters() }
    }

    private func resumeWaiters() {
        guard manager.authorizationStatus != .notDetermined else { return }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

struct WiFiPasswordView: View {
    let tool: ToolDescriptor
    @State private var location = LocationAccess()
    @State private var name = ""
    @State private var security: WiFiSecurity = .wpa
    @State private var isHidden = false
    @State private var password: String?
    @State private var qrImage: CGImage?
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        ToolPage(tool: tool) {
            Form {
                LabeledContent(L("Network")) {
                    HStack {
                        TextField(L("Network name"), text: $name).labelsHidden()
                        Button(L("Use Current Network"), action: useCurrentNetwork)
                    }
                }
                Picker(L("Security"), selection: $security) {
                    Text(verbatim: "WPA/WPA2/WPA3").tag(WiFiSecurity.wpa)
                    Text(verbatim: "WEP").tag(WiFiSecurity.wep)
                    Text(L("None")).tag(WiFiSecurity.open)
                }
                Toggle(L("Hidden network"), isOn: $isHidden)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560, maxHeight: 200)

            HStack {
                Button(L("Show Password"), action: reveal)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isWorking || security == .open)
                if isWorking { ProgressView().controlSize(.small) }
                if security == .open {
                    Button(L("Make QR Code")) { makeQR(password: "") }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Spacer()
            }
            Text(L("macOS asks for an administrator's name and password before it shows a saved Wi-Fi password."))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let password {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Password")).font(.headline)
                        Text(password).font(.title3.monospaced()).textSelection(.enabled)
                        Button(L("Copy Password")) { Clipboard.copy(password) }
                    }
                    if let qrImage {
                        VStack(spacing: 6) {
                            Image(decorative: qrImage, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 180, height: 180)
                            Text(L("Scan with a phone's camera to join."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let qrImage {
                Image(decorative: qrImage, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 180, height: 180)
            }
        }
        .onAppear {
            if location.isAuthorized, name.isEmpty, let current = WiFiPassword.currentNetworkName() { name = current }
        }
        .onChange(of: name) { clear() }
        .onChange(of: security) { clear() }
        .onChange(of: isHidden) { clear() }
        .onDisappear { clear() }
        .reportsActivity(isWorking)
    }

    private func clear() {
        password = nil
        qrImage = nil
        message = nil
    }

    private func useCurrentNetwork() {
        Task {
            await location.request()
            if let current = WiFiPassword.currentNetworkName() {
                name = current
            } else if location.isDenied {
                message = L(
                    "Allow OpenToolbox in System Settings → Privacy & Security → Location Services to see the current network's name, or type it.")
            } else {
                message = L("This Mac isn't joined to a Wi-Fi network right now. Type the network's name.")
            }
        }
    }

    private func reveal() {
        let ssid = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            let result = await runOffMain { Result { try WiFiPassword.savedPassword(for: ssid) } }
            switch result {
            case .success(let found):
                guard ssid == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                password = found
                makeQR(password: found)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func makeQR(password: String) {
        let payload = WiFiPassword.qrPayload(
            ssid: name.trimmingCharacters(in: .whitespacesAndNewlines), password: password, security: security,
            hidden: isHidden)
        qrImage = try? QRCode.generate(payload)
    }
}

// MARK: - Reset Permissions

struct ResetPermissionsView: View {
    let tool: ToolDescriptor
    @State private var app: PrivacyApp?
    @State private var service: PrivacyService = .all
    @State private var isConfirming = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var failure: String?
    @State private var isTargeted = false

    var body: some View {
        ToolPage(tool: tool) {
            HStack(spacing: 12) {
                if let app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text(app.bundleIdentifier).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L("Drop an app here or choose one.")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Choose App…"), action: chooseApp)
            }
            .padding(12)
            .background(
                (isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                select(url)
                return true
            } isTargeted: { isTargeted = $0 }

            Form {
                Picker(L("Permission"), selection: $service) {
                    ForEach(PrivacyService.services) { service in
                        Text(service.localizedTitle).tag(service)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560, maxHeight: 90)

            HStack {
                Button(L("Reset…")) { isConfirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(app == nil || isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Open Privacy Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text(L("The app asks again the next time it needs the permission. Quit and reopen it if it's running."))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if let failure {
                ErrorMessage(text: failure)
            }
        }
        .confirmationDialog(
            L("Reset \(service.localizedTitle) for \(app?.name ?? "")?"), isPresented: $isConfirming
        ) {
            Button(L("Reset"), role: .destructive, action: reset)
        } message: {
            Text(L("macOS forgets whether you allowed or denied it."))
        }
        .reportsActivity(isWorking)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    private func select(_ url: URL) {
        message = nil
        failure = nil
        do {
            app = try PrivacyApp(url: url)
        } catch {
            app = nil
            failure = error.localizedDescription
        }
    }

    private func reset() {
        guard let app else { return }
        let service = self.service
        isWorking = true
        message = nil
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                try await PrivacyPermissions.reset(service, for: app)
                message = L("Reset \(service.localizedTitle) for \(app.name).")
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
