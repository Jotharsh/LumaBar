import XCTest
@testable import LumaBarCore

final class MathTests: XCTestCase {
    func testSunsetLondonMidsummer() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let day = calendar.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 9))!
        let sunset = try XCTUnwrap(SunCalc.sunset(on: day, latitude: 51.5074, longitude: -0.1278, calendar: calendar))
        // Published sunset: 21:21 BST.
        let expected = calendar.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 21, minute: 21))!
        XCTAssertEqual(sunset.timeIntervalSince(expected), 0, accuracy: 5 * 60)
    }

    func testSunsetNewYorkWinter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2024, month: 12, day: 21, hour: 9))!
        let sunset = try XCTUnwrap(SunCalc.sunset(on: day, latitude: 40.7128, longitude: -74.0060, calendar: calendar))
        // Published sunset: 16:32 EST.
        let expected = calendar.date(from: DateComponents(year: 2024, month: 12, day: 21, hour: 16, minute: 32))!
        XCTAssertEqual(sunset.timeIntervalSince(expected), 0, accuracy: 5 * 60)
    }

    func testNoSunsetInPolarNight() {
        let day = Date(timeIntervalSince1970: 1_734_739_200) // 2024-12-21
        XCTAssertNil(SunCalc.sunset(on: day, latitude: 78.2, longitude: 15.6))
    }

    func testRampProgress() {
        let sunset = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SunsetRamp.progress(now: sunset.addingTimeInterval(-60), sunset: sunset, duration: 3600), 0)
        XCTAssertEqual(SunsetRamp.progress(now: sunset.addingTimeInterval(1800), sunset: sunset, duration: 3600), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SunsetRamp.progress(now: sunset.addingTimeInterval(9999), sunset: sunset, duration: 3600), 1)
        XCTAssertEqual(SunsetRamp.interpolate(from: 4000, to: 2200, progress: 0.5), 3100, accuracy: 1e-9)
    }

    func testHueToRGB() {
        XCTAssertEqual(ColorMath.rgb(hue: 0), RGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(ColorMath.rgb(hue: 1.0 / 3), RGB(r: 0, g: 255, b: 0))
        XCTAssertEqual(ColorMath.rgb(hue: 2.0 / 3), RGB(r: 0, g: 0, b: 255))
        XCTAssertEqual(ColorMath.rgb(hue: 0, saturation: 0), RGB(r: 255, g: 255, b: 255))
    }

    func testRGBToHueRoundTrip() {
        for hue in stride(from: 0.0, to: 1.0, by: 0.1) {
            XCTAssertEqual(ColorMath.hue(of: ColorMath.rgb(hue: hue)), hue, accuracy: 0.01)
        }
    }

    func testScreenParamsNormalisesColourAndTracksBrightness() {
        let params = ColorMath.screenParams(r: 100, g: 50, b: 0)
        let rgb = try! XCTUnwrap(params.rgb)
        XCTAssertEqual(rgb.r, 255)
        XCTAssertEqual(Double(rgb.g), 127.5, accuracy: 1)
        XCTAssertEqual(rgb.b, 0)
        XCTAssertEqual(params.dimming, 39)
        XCTAssertEqual(ColorMath.screenParams(r: 0, g: 0, b: 0).dimming, 10)
    }
}
