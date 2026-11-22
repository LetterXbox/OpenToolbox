import AppKit
import MapKit
import OpenToolboxCore
import SwiftUI


struct ColorPickerView: View {
    let tool: ToolDescriptor
    @State private var color = SRGBColor(red: 0.2, green: 0.47, blue: 0.95)
    @State private var hexInput = ""
    @State private var history: [SRGBColor] = []
    @State private var sampler: NSColorSampler?

    var body: some View {
        ToolPage(tool: tool) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                        .frame(width: 140, height: 140)
                    Button(L("Pick from Screen"), systemImage: "eyedropper", action: sample)
                        .buttonStyle(.borderedProminent)
                    TextField(L("Hex"), text: $hexInput, prompt: Text(verbatim: "#3478F6"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit(applyHex)
                }
                Form {
                    formatRow(L("Hex"), color.hex)
                    formatRow(L("RGB"), color.rgb)
                    formatRow(L("HSL"), color.hsl)
                    formatRow(L("HSB"), color.hsb)
                    formatRow(verbatim: "SwiftUI", color.swiftUI)
                    formatRow(verbatim: "AppKit", color.appKit)
                }
                .formStyle(.grouped)
                .frame(maxWidth: 560, maxHeight: 300)
            }
            if !history.isEmpty {
                Pane(L("Recent")) {
                    HStack(spacing: 8) {
                        ForEach(history, id: \.self) { item in
                            Button {
                                color = item
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(.sRGB, red: item.red, green: item.green, blue: item.blue, opacity: item.alpha))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help(item.hex)
                        }
                    }
                }
            }
        }
    }

    private func formatRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { copyableValue(value) }
    }

    private func formatRow(verbatim title: String, _ value: String) -> some View {
        LabeledContent { copyableValue(value) } label: { Text(verbatim: title) }
    }

    private func copyableValue(_ value: String) -> some View {
        HStack {
            Text(value).font(.body.monospaced()).textSelection(.enabled).lineLimit(1)
            Button(L("Copy"), systemImage: "doc.on.doc") { Clipboard.copy(value) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func sample() {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { picked in
            let rgb = picked?.usingColorSpace(.sRGB).map {
                SRGBColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: $0.alphaComponent)
            }
            Task { @MainActor in
                self.sampler = nil
                if let rgb { use(rgb) }
            }
        }
    }

    private func applyHex() {
        if let parsed = SRGBColor(hex: hexInput) { use(parsed) }
    }

    private func use(_ new: SRGBColor) {
        color = new
        history.removeAll { $0 == new }
        history.insert(new, at: 0)
        if history.count > 12 { history.removeLast(history.count - 12) }
    }
}


struct CoordinatePickerView: View {
    let tool: ToolDescriptor
    @State private var position: MapCameraPosition = .automatic
    @State private var coordinate: GeoCoordinate?
    @State private var query = ""
    @State private var input = ""
    @State private var message: String?
    @State private var isSearching = false

    var body: some View {
        ToolPage(tool: tool) {
            HStack {
                TextField(L("Search for a place"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button(L("Search"), action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                if isSearching { ProgressView().controlSize(.small) }
                Divider().frame(height: 18)
                TextField(L("Or enter coordinates"), text: $input, prompt: Text(verbatim: "48.8584, 2.2945"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(applyInput)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            MapReader { proxy in
                Map(position: $position) {
                    if let coordinate {
                        Marker(
                            coordinate.decimal,
                            coordinate: CLLocationCoordinate2D(
                                latitude: coordinate.latitude, longitude: coordinate.longitude))
                    }
                }
                .onTapGesture { point in
                    guard let location = proxy.convert(point, from: .local) else { return }
                    coordinate = GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
                    message = nil
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 260)

            if let coordinate {
                Form {
                    row(L("Latitude, longitude"), coordinate.decimal)
                    row(L("Latitude"), coordinate.latitudeText)
                    row(L("Longitude"), coordinate.longitudeText)
                    row(L("Degrees, minutes, seconds"), coordinate.degreesMinutesSeconds)
                    row(verbatim: "GeoJSON", coordinate.geoJSON)
                }
                .formStyle(.grouped)
                .frame(maxHeight: 250)
            } else {
                Text(L("Click the map to drop a pin."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { copyable(value) }
    }

    private func row(verbatim title: String, _ value: String) -> some View {
        LabeledContent { copyable(value) } label: { Text(verbatim: title) }
    }

    private func copyable(_ value: String) -> some View {
        HStack {
            Text(value).font(.body.monospaced()).textSelection(.enabled)
            Button(L("Copy"), systemImage: "doc.on.doc") { Clipboard.copy(value) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func show(_ new: GeoCoordinate) {
        coordinate = new
        position = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: new.latitude, longitude: new.longitude),
                latitudinalMeters: 2_000, longitudinalMeters: 2_000))
    }

    private func applyInput() {
        if let parsed = GeoCoordinate.parse(input) {
            show(parsed)
            message = nil
        } else {
            message = L("Enter coordinates as latitude, longitude, for example 48.8584, 2.2945.")
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        message = nil
        Task {
            defer { isSearching = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard let item = response.mapItems.first else {
                    message = L("No places found.")
                    return
                }
                let location = item.placemark.coordinate
                if let found = GeoCoordinate(latitude: location.latitude, longitude: location.longitude) {
                    show(found)
                    message = item.name
                }
            } catch {
                message = L("The search didn't finish: \(error.localizedDescription)")
            }
        }
    }
}
