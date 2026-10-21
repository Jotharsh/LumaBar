import Foundation

/// Sunset time from the NOAA/Wikipedia "sunrise equation". Accurate to a few minutes, which is plenty here.
public enum SunCalc {
    /// Sunset on the calendar day containing `date` at the given location, or nil during polar day/night.
    public static func sunset(on date: Date, latitude: Double, longitude: Double, calendar: Calendar = .current) -> Date? {
        // Day number counted from J2000.0, using the calendar date as seen in the caller's time zone.
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let utcNoon = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) else { return nil }
        let julianDate = utcNoon.timeIntervalSince1970 / 86400 + 2440587.5
        let n = (julianDate - 2451545.0).rounded()
        let meanSolarTime = n - longitude / 360
        let m = (357.5291 + 0.98560028 * meanSolarTime).truncatingRemainder(dividingBy: 360)
        let mRad = radians(m)
        let c = 1.9148 * sin(mRad) + 0.02 * sin(2 * mRad) + 0.0003 * sin(3 * mRad)
        let lambda = (m + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let lambdaRad = radians(lambda)
        let transit = 2451545.0 + meanSolarTime + 0.0053 * sin(mRad) - 0.0069 * sin(2 * lambdaRad)
        let sinDecl = sin(lambdaRad) * sin(radians(23.4397))
        let cosDecl = cos(asin(sinDecl))
        let latRad = radians(latitude)
        let cosHour = (sin(radians(-0.833)) - sin(latRad) * sinDecl) / (cos(latRad) * cosDecl)
        guard abs(cosHour) <= 1 else { return nil }
        let hourAngle = degrees(acos(cosHour))
        let setJulian = transit + hourAngle / 360
        return Date(timeIntervalSince1970: (setJulian - 2440587.5) * 86400)
    }

    private static func radians(_ d: Double) -> Double { d * .pi / 180 }
    private static func degrees(_ r: Double) -> Double { r * 180 / .pi }
}

public enum SunsetRamp {
    /// 0 before sunset, rising linearly to 1 once `duration` has passed.
    public static func progress(now: Date, sunset: Date, duration: TimeInterval) -> Double {
        guard duration > 0 else { return now >= sunset ? 1 : 0 }
        return min(max(now.timeIntervalSince(sunset) / duration, 0), 1)
    }

    public static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + (end - start) * progress
    }
}
