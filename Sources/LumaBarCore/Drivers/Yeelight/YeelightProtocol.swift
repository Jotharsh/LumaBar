import Foundation

/// Yeelight's LAN protocol: JSON lines over TCP port 55443, discovery by an SSDP-style multicast search.
enum YeelightProtocol {
    static let port: UInt16 = 55443
    static let searchAddress = "239.255.255.250"
    static let searchPort: UInt16 = 1982

    static let searchMessage = Data(
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n".utf8)

    /// `{"id":1,"method":"set_power","params":["on","smooth",300]}\r\n`
    static func request(id: Int, method: String, params: [Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params], options: [.sortedKeys])) ?? Data()
        return body + Data("\r\n".utf8)
    }

    enum Reply: Equatable {
        case ok([String])
        case error(code: Int, message: String)
        case notification        // unsolicited {"method":"props",...}: not a reply to anything
    }

    static func parseReply(_ line: Data) -> (id: Int?, reply: Reply)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["method"] != nil { return (nil, .notification) }
        let id = object["id"] as? Int
        if let error = object["error"] as? [String: Any] {
            return (id, .error(code: error["code"] as? Int ?? -1, message: error["message"] as? String ?? "unknown error"))
        }
        let result = (object["result"] as? [Any])?.map { "\($0)" } ?? []
        return (id, .ok(result))
    }

    /// What a bulb says about itself when it answers a search.
    struct Advertisement: Equatable {
        var id: String
        var host: String
        var port: UInt16
        var model: String
        var supported: Set<String>
        var name: String
        var isOn: Bool
        var brightness: Int?

        var capabilities: DeviceCapabilities {
            var caps: DeviceCapabilities = [.power]
            if supported.contains("set_bright") { caps.insert(.brightness) }
            if supported.contains("set_ct_abx") { caps.insert(.colorTemp) }
            if supported.contains("set_rgb") { caps.insert(.color) }
            return caps
        }
    }

    static func parseAdvertisement(_ datagram: Datagram) -> Advertisement? {
        guard let text = String(data: datagram.data, encoding: .utf8), text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("NOTIFY") else { return nil }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let id = headers["id"], !id.isEmpty else { return nil }

        var host = datagram.source
        var port = YeelightProtocol.port
        if let location = headers["location"], let url = URL(string: location), let h = url.host {
            host = h
            port = url.port.flatMap { UInt16(exactly: $0) } ?? port
        }
        return Advertisement(
            id: id, host: host, port: port, model: headers["model"] ?? "",
            supported: Set((headers["support"] ?? "").split(separator: " ").map(String.init)),
            name: headers["name"] ?? "", isOn: headers["power"] == "on", brightness: headers["bright"].flatMap { Int($0) })
    }
}
