import XCTest
import Network
@testable import LumaBarCore

/// A stand-in bulb: a UDP listener on localhost that answers like a WiZ bulb.
private final class FakeBulb: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeBulb")
    private let lock = NSLock()
    private var _received: [String] = []
    private var dropNext: Int

    var received: [String] { lock.lock(); defer { lock.unlock() }; return _received }

    init(port: UInt16, dropFirst: Int = 0) throws {
        self.port = port
        self.dropNext = dropFirst
        listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            self.serve(connection)
        }
    }

    func start() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let flag = Flag()
            listener.stateUpdateHandler = { state in
                if case .ready = state, flag.setOnce() { c.resume() }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.receiveMessage { [unowned self] data, _, _, error in
            if let data {
                let text = String(decoding: data, as: UTF8.self)
                lock.lock(); _received.append(text)
                let drop = dropNext > 0
                if drop { dropNext -= 1 }
                lock.unlock()
                if !drop { connection.send(content: reply(for: text), completion: .contentProcessed { _ in }) }
            }
            if error == nil { serve(connection) }
        }
    }

    private func reply(for request: String) -> Data {
        if request.contains("registration") {
            return Data(#"{"method":"registration","env":"pro","result":{"mac":"a8bb50aabbcc","success":true}}"#.utf8)
        }
        if request.contains("getPilot") {
            return Data(#"{"method":"getPilot","env":"pro","result":{"mac":"a8bb50aabbcc","state":true,"sceneId":0,"temp":3000,"dimming":65}}"#.utf8)
        }
        return Data(#"{"method":"setPilot","env":"pro","result":{"success":true}}"#.utf8)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var set = false
    func setOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if set { return false }; set = true; return true }
}

final class WizClientTests: XCTestCase {
    func testGetPilotRoundTrip() async throws {
        let bulb = try FakeBulb(port: 48911)
        await bulb.start(); defer { bulb.stop() }
        let client = WizClient(bulbPort: 48911, timeout: 1)

        let state = try await client.getPilot(host: "127.0.0.1")
        XCTAssertEqual(state, BulbState(isOn: true, dimming: 65, temperature: 3000))
        XCTAssertEqual(bulb.received, [#"{"method":"getPilot"}"#])
    }

    func testSetPilotSendsExpectedJSON() async throws {
        let bulb = try FakeBulb(port: 48912)
        await bulb.start(); defer { bulb.stop() }
        let client = WizClient(bulbPort: 48912, timeout: 1)

        try await client.setPilot(LightCommand(state: true, dimming: 30, temp: 2700), host: "127.0.0.1")
        XCTAssertEqual(bulb.received, [#"{"method":"setPilot","params":{"dimming":30,"state":true,"temp":2700}}"#])
    }

    func testRetriesOnceWhenFirstDatagramIsLost() async throws {
        let bulb = try FakeBulb(port: 48913, dropFirst: 1)
        await bulb.start(); defer { bulb.stop() }
        let client = WizClient(bulbPort: 48913, timeout: 0.5)

        try await client.setPilot(.power(false), host: "127.0.0.1")
        XCTAssertEqual(bulb.received.count, 2, "first send is dropped, the retry gets through")
    }

    func testGivesUpAfterOneRetry() async throws {
        let bulb = try FakeBulb(port: 48914, dropFirst: 99)
        await bulb.start(); defer { bulb.stop() }
        let client = WizClient(bulbPort: 48914, timeout: 0.3)

        do {
            try await client.setPilot(.power(true), host: "127.0.0.1")
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? WizError, .timeout)
        }
        XCTAssertEqual(bulb.received.count, 2, "one attempt plus exactly one retry")
    }

    func testOfflineBulbFailsInsteadOfHanging() async throws {
        let client = WizClient(bulbPort: 48915, timeout: 0.3)   // nothing listening
        let start = Date()
        do {
            _ = try await client.getPilot(host: "127.0.0.1")
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? WizError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    /// Sends a real broadcast to 255.255.255.255 and expects the fake bulb's unicast reply to find the listener.
    func testDiscoveryFindsBulbAnsweringABroadcast() async throws {
        let ip = try XCTUnwrap(LocalNetwork.ipv4Address(), "needs a LAN interface")
        let bulb = try FakeBulb(port: 48920)
        await bulb.start(); defer { bulb.stop() }
        let client = WizClient(bulbPort: 48920, listenPort: 48921, timeout: 1)

        let found = await client.discover(duration: 1.5, localIP: ip)
        XCTAssertEqual(found.map(\.mac), ["a8bb50aabbcc"])
        XCTAssertEqual(found.first?.ip, ip)
        XCTAssertTrue(bulb.received.contains { $0.contains("registration") && $0.contains(ip) })
    }
}
