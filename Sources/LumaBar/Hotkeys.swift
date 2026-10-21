import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleLight = Self("toggleLight", default: .init(.l, modifiers: [.control, .option]))
    static let brightnessUp = Self("brightnessUp", default: .init(.upArrow, modifiers: [.control, .option]))
    static let brightnessDown = Self("brightnessDown", default: .init(.downArrow, modifiers: [.control, .option]))
}
