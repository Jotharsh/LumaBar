import AppKit

/// The pendant-lamp glyph shown in the menu bar: the beam of light appears only while the light is on.
/// They're template images, so macOS tints them for light and dark menu bars.
enum MenuBarIcon {
    private static let on = load("MenuBarOn")
    private static let off = load("MenuBarOff")

    /// Nil if the image files aren't in the app bundle (for example under `swift run`); callers fall back to a system symbol.
    static func image(isOn: Bool) -> NSImage? { isOn ? on : off }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)     // the PNGs are 72 px: 4x, so they stay sharp on Retina displays
        image.isTemplate = true
        return image
    }
}
