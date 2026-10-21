import Foundation

/// What a particular bulb can do. The UI shows only the controls its bulbs support.
public struct DeviceCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let power = DeviceCapabilities(rawValue: 1 << 0)
    public static let brightness = DeviceCapabilities(rawValue: 1 << 1)
    public static let colorTemp = DeviceCapabilities(rawValue: 1 << 2)
    public static let color = DeviceCapabilities(rawValue: 1 << 3)
    public static let scenes = DeviceCapabilities(rawValue: 1 << 4)

    public static let fullColor: DeviceCapabilities = [.power, .brightness, .colorTemp, .color]
}
