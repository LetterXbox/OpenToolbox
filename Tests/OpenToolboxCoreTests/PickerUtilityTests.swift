import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import OpenToolboxCore

@Suite("Crop PDF")
struct CropPDFTests {
    let box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let margins = PDFMargins(top: 10, left: 20, bottom: 30, right: 40)

    @Test(arguments: [
        (0, CGRect(x: 20, y: 30, width: 540, height: 760)),
        (90, CGRect(x: 10, y: 20, width: 560, height: 740)),
        (180, CGRect(x: 40, y: 10, width: 540, height: 760)),
        (270, CGRect(x: 30, y: 40, width: 560, height: 740)),
        (-90, CGRect(x: 30, y: 40, width: 560, height: 740)),
    ])
    func marginsFollowTheShownPage(rotation: Int, expected: CGRect) {
        #expect(PDFCrop.cropRect(box, margins: margins, rotation: rotation) == expected)
    }

    @Test func offsetBoxesKeepTheirOrigin() {
        let shifted = CGRect(x: 100, y: 50, width: 600, height: 800)
        #expect(
            PDFCrop.cropRect(shifted, margins: margins, rotation: 0)
                == CGRect(x: 120, y: 80, width: 540, height: 760))
    }

    @Test func refusesMarginsThatLeaveNothing() throws {
        #expect(PDFCrop.cropRect(box, margins: PDFMargins(left: 300, right: 300), rotation: 0) == nil)
        #expect(PDFCrop.cropRect(box, margins: PDFMargins(top: -1), rotation: 0) == nil)
        let document = try samplePDF(pages: 2)
        #expect(throws: PDFCropError.marginsTooLarge(page: 1)) {
            try PDFCrop.crop(document, margins: PDFMargins(top: 5_000))
        }
    }

    @Test func cropBoxSurvivesSaving() async throws {
        try await withTemporaryDirectory { directory in
            let document = try samplePDF(pages: 3)
            let original = try #require(document.page(at: 0)).bounds(for: .cropBox)
            let cropped = try PDFCrop.crop(document, pages: [0, 2], margins: PDFMargins(top: 10, left: 10, bottom: 10, right: 10))
            let url = directory.appending(path: "cropped.pdf")
            try PDFTools.write(cropped, to: url)
            let reopened = try PDFTools.open(url)
            let first = try #require(reopened.page(at: 0)).bounds(for: .cropBox)
            let second = try #require(reopened.page(at: 1)).bounds(for: .cropBox)
            #expect(first.width == original.width - 20)
            #expect(first.height == original.height - 20)
            #expect(second.size == original.size)
            #expect(try #require(document.page(at: 0)).bounds(for: .cropBox) == original)
        }
    }

    @Test func millimetersBecomePoints() {
        let margins = PDFMargins.millimeters(top: 25.4, left: 0, bottom: 0, right: 0)
        #expect(abs(margins.top - 72) < 0.0001)
        #expect(!margins.isZero)
        #expect(PDFMargins().isZero)
    }
}

@Suite("Color formats")
struct ColorFormatTests {
    @Test func parsesHex() throws {
        let color = try #require(RGBColor(hex: "#3478F6"))
        #expect(color.hex == "#3478F6")
        #expect(color.rgb == "rgb(52, 120, 246)")
        #expect(RGBColor(hex: "fff")?.hex == "#FFFFFF")
        #expect(RGBColor(hex: "#11223380")?.hex == "#11223380")
        #expect(RGBColor(hex: "#12345") == nil)
        #expect(RGBColor(hex: "#GGGGGG") == nil)
        #expect(RGBColor(hex: "") == nil)
    }

    @Test func hslAndHSB() {
        let red = RGBColor(red: 1, green: 0, blue: 0)
        #expect(red.hsl == "hsl(0, 100%, 50%)")
        #expect(red.hsb == "0°, 100%, 100%")
        let gray = RGBColor(red: 0.5, green: 0.5, blue: 0.5)
        #expect(gray.hsl == "hsl(0, 0%, 50%)")
        let teal = RGBColor(red: 0, green: 0.5, blue: 0.5)
        #expect(teal.hsl == "hsl(180, 100%, 25%)")
        #expect(RGBColor(red: 0, green: 0, blue: 1).hsl == "hsl(240, 100%, 50%)")
        #expect(RGBColor(red: 1, green: 0, blue: 1).hsb == "300°, 100%, 100%")
    }

    @Test func codeSnippetsAndAlpha() {
        let color = RGBColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        #expect(color.swiftUI == "Color(red: 0.2, green: 0.4, blue: 0.6, opacity: 0.5)")
        #expect(color.appKit == "NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)")
        #expect(color.rgb == "rgb(51, 102, 153 / 0.5)")
        #expect(RGBColor(red: 2, green: -1, blue: .nan).hex == "#FF0000")
    }
}

@Suite("Coordinates")
struct CoordinateTests {
    @Test func parsesDecimal() throws {
        let point = try #require(GeoCoordinate.parse("48.8584, 2.2945"))
        #expect(point.latitude == 48.8584)
        #expect(point.longitude == 2.2945)
        #expect(GeoCoordinate.parse("-33.8568 151.2153")?.longitude == 151.2153)
        #expect(GeoCoordinate.parse("91, 0") == nil)
        #expect(GeoCoordinate.parse("0, 181") == nil)
        #expect(GeoCoordinate.parse("1, 2, 3") == nil)
        #expect(GeoCoordinate.parse("") == nil)
    }

    @Test func parsesDegreesMinutesSeconds() throws {
        let point = try #require(GeoCoordinate.parse("48°51'30\"N 2°17'40\"E"))
        #expect(abs(point.latitude - 48.858333) < 0.00001)
        #expect(abs(point.longitude - 2.294444) < 0.00001)
        let south = try #require(GeoCoordinate.parse("33°51′24.5″S 151°12′55.1″E"))
        #expect(south.latitude < 0)
        #expect(GeoCoordinate.parse("40.7128 N, 74.0060 W")?.longitude == -74.006)
        #expect(GeoCoordinate.parse("48°51'30\"N") == nil)
    }

    @Test func formats() throws {
        let point = try #require(GeoCoordinate(latitude: -33.856784, longitude: 151.215297))
        #expect(point.decimal == "-33.856784, 151.215297")
        #expect(point.geoJSON == "[151.215297, -33.856784]")
        #expect(point.degreesMinutesSeconds == "33°51′24.4″S 151°12′55.1″E")
        let roundTrip = try #require(GeoCoordinate.parse(point.degreesMinutesSeconds))
        #expect(abs(roundTrip.latitude - point.latitude) < 0.0001)
    }
}

@Suite("Wi-Fi QR code")
struct WiFiQRTests {
    @Test func buildsPayload() {
        #expect(
            WiFiPassword.qrPayload(ssid: "Home", password: "hunter22", security: .wpa)
                == "WIFI:T:WPA;S:Home;P:hunter22;;")
        #expect(WiFiPassword.qrPayload(ssid: "Café", password: "", security: .open) == "WIFI:T:nopass;S:Café;;")
        #expect(
            WiFiPassword.qrPayload(ssid: "Lab", password: "k", security: .wep, hidden: true)
                == "WIFI:T:WEP;S:Lab;P:k;H:true;;")
    }

    @Test func escapesSpecialCharacters() {
        #expect(
            WiFiPassword.qrPayload(ssid: "a;b,c", password: #"p:q"r\s"#, security: .wpa)
                == #"WIFI:T:WPA;S:a\;b\,c;P:p\:q\"r\\s;;"#)
    }

    @Test func refusesEmptyName() {
        #expect(throws: WiFiPasswordError.emptyName) { try WiFiPassword.savedPassword(for: "  ") }
    }
}

@Suite("Reset permissions")
struct PrivacyPermissionTests {
    @Test func buildsArguments() throws {
        let camera = try #require(PrivacyService.services.first { $0.id == "Camera" })
        #expect(
            try PrivacyPermissions.arguments(service: camera, bundleIdentifier: "com.example.App")
                == ["reset", "Camera", "com.example.App"])
        #expect(try PrivacyPermissions.arguments(service: .all, bundleIdentifier: "org.x-y_z") == ["reset", "All", "org.x-y_z"])
    }

    @Test(arguments: ["", "-all", "com.example app", "com/example", "com.exämple", String(repeating: "a", count: 256)])
    func refusesBadIdentifiers(identifier: String) {
        #expect(throws: PrivacyPermissionError.invalidIdentifier(identifier)) {
            try PrivacyPermissions.validate(identifier)
        }
    }

    @Test func readsAnAppBundle() async throws {
        try await withTemporaryDirectory { directory in
            let app = directory.appending(path: "Sample.app/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "com.example.Sample", "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: app.appending(path: "Info.plist"))
            let parsed = try PrivacyApp(url: directory.appending(path: "Sample.app"))
            #expect(parsed.bundleIdentifier == "com.example.Sample")
            #expect(throws: PrivacyPermissionError.self) { try PrivacyApp(url: directory) }
        }
    }

    @Test func servicesAreUnique() {
        let ids = PrivacyService.services.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "All")
    }
}
