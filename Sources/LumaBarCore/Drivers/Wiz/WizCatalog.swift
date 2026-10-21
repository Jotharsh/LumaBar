import Foundation

extension LightScene {
    /// The built-in WiZ lighting scenes, as sent in `sceneId`.
    public static let wiz: [LightScene] = [
        LightScene(id: 1, name: "Ocean", isDynamic: true),
        LightScene(id: 2, name: "Romance", isDynamic: true),
        LightScene(id: 3, name: "Sunset", isDynamic: true),
        LightScene(id: 4, name: "Party", isDynamic: true),
        LightScene(id: 5, name: "Fireplace", isDynamic: true),
        LightScene(id: 6, name: "Cozy", isDynamic: true),
        LightScene(id: 7, name: "Forest", isDynamic: true),
        LightScene(id: 8, name: "Pastel Colors", isDynamic: true),
        LightScene(id: 9, name: "Wake Up", isDynamic: true),
        LightScene(id: 10, name: "Bedtime", isDynamic: true),
        LightScene(id: 11, name: "Warm White", isDynamic: false),
        LightScene(id: 12, name: "Daylight", isDynamic: false),
        LightScene(id: 13, name: "Cool White", isDynamic: false),
        LightScene(id: 14, name: "Night Light", isDynamic: false),
        LightScene(id: 15, name: "Focus", isDynamic: false),
        LightScene(id: 16, name: "Relax", isDynamic: false),
        LightScene(id: 17, name: "True Colors", isDynamic: false),
        LightScene(id: 18, name: "TV Time", isDynamic: false),
        LightScene(id: 19, name: "Plantgrowth", isDynamic: false),
        LightScene(id: 20, name: "Spring", isDynamic: true),
        LightScene(id: 21, name: "Summer", isDynamic: true),
        LightScene(id: 22, name: "Fall", isDynamic: true),
        LightScene(id: 23, name: "Deep Dive", isDynamic: true),
        LightScene(id: 24, name: "Jungle", isDynamic: true),
        LightScene(id: 25, name: "Mojito", isDynamic: true),
        LightScene(id: 26, name: "Club", isDynamic: true),
        LightScene(id: 27, name: "Christmas", isDynamic: true),
        LightScene(id: 28, name: "Halloween", isDynamic: true),
        LightScene(id: 29, name: "Candlelight", isDynamic: true),
        LightScene(id: 30, name: "Golden White", isDynamic: false),
        LightScene(id: 31, name: "Pulse", isDynamic: true),
        LightScene(id: 32, name: "Steampunk", isDynamic: true),
    ]

    public static func wizScene(id: Int) -> LightScene? { wiz.first { $0.id == id } }

    public static let defaultSpeed = 100
}

