import Foundation

public enum ColorMath {
    /// HSV (all 0...1) to RGB.
    public static func rgb(hue: Double, saturation: Double = 1, value: Double = 1) -> RGB {
        let h = (hue - hue.rounded(.down)) * 6
        let i = Int(h)
        let f = h - Double(i)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (value, t, p)
        case 1: (r, g, b) = (q, value, p)
        case 2: (r, g, b) = (p, value, t)
        case 3: (r, g, b) = (p, q, value)
        case 4: (r, g, b) = (t, p, value)
        default: (r, g, b) = (value, p, q)
        }
        return RGB(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
    }

    /// Hue (0...1) of an RGB colour; 0 for greys.
    public static func hue(of rgb: RGB) -> Double {
        let r = Double(rgb.r) / 255, g = Double(rgb.g) / 255, b = Double(rgb.b) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        let d = maxV - minV
        guard d > 0 else { return 0 }
        var h: Double
        if maxV == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxV == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    /// Saturation (0...1) of an RGB colour; 0 for white and grey.
    public static func saturation(of rgb: RGB) -> Double {
        let maxV = Double(max(rgb.r, rgb.g, rgb.b))
        guard maxV > 0 else { return 0 }
        return (maxV - Double(min(rgb.r, rgb.g, rgb.b))) / maxV
    }

    /// Converts an average screen colour (channels 0...255) into a bulb command.
    /// The bulb takes colour and brightness separately, so the colour is normalised to full
    /// intensity and the brightness follows the screen's brightness.
    public static func screenParams(r: Double, g: Double, b: Double) -> LightCommand {
        let m = max(r, g, b)
        guard m >= 1 else { return LightCommand(state: true, dimming: WizLimits.dimming.lowerBound, rgb: RGB(r: 255, g: 255, b: 255)) }
        let k = 255 / m
        let rgb = RGB(r: Int((r * k).rounded()), g: Int((g * k).rounded()), b: Int((b * k).rounded()))
        return LightCommand(state: true, dimming: Int((m / 255 * 100).rounded()), rgb: rgb)
    }
}
