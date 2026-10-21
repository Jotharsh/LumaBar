import Foundation

/// A named lighting scene a bulb can run. Only drivers that report the `scenes` capability have any.
public struct LightScene: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int
    public let name: String
    /// Animated scenes honour the `speed` setting; static ones (plain whites and the like) don't.
    public let isDynamic: Bool

    public init(id: Int, name: String, isDynamic: Bool) {
        self.id = id
        self.name = name
        self.isDynamic = isDynamic
    }
}
