import Foundation
import Network

/// A byte pipe to one device (Tuya, Yeelight). Real devices use `NWByteChannel` (TCP); tests substitute a fake.
public protocol ByteChannel: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// The next chunk of bytes from the device. Throws `DriverError.unreachable` on timeout or close.
    func receive() async throws -> Data
    func close()
}

public typealias ByteConnector = @Sendable (_ host: String, _ port: UInt16) async throws -> ByteChannel

/// Resumes a continuation exactly once, whichever of result / failure / timeout comes first.
final class OnceContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private let onFinish: () -> Void

    init(_ continuation: CheckedContinuation<T, Error>, onFinish: @escaping () -> Void = {}) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func succeed(_ value: T) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        onFinish()
        continuation.resume(with: result)
    }
}

public final class NWByteChannel: ByteChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "LumaBar.ByteChannel")
    private let timeout: TimeInterval

    private init(connection: NWConnection, timeout: TimeInterval) {
        self.connection = connection
        self.timeout = timeout
    }

    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 3) async throws -> NWByteChannel {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw DriverError.unreachable("Bad port.") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let channel = NWByteChannel(connection: connection, timeout: timeout)
        let queue = channel.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceContinuation(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.succeed(())
                case .failed(let error): once.fail(DriverError.unreachable(error.localizedDescription))
                case .waiting(let error): once.fail(DriverError.unreachable(error.localizedDescription))
                case .cancelled: once.fail(DriverError.unreachable("Connection cancelled."))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.fail(DriverError.unreachable("The device didn't accept a connection.")) }
        }
        connection.stateUpdateHandler = nil
        return channel
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: DriverError.unreachable(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = OnceContinuation(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data, !data.isEmpty { once.succeed(data) }
                else if let error { once.fail(DriverError.unreachable(error.localizedDescription)) }
                else if isComplete { once.fail(DriverError.unreachable("The device closed the connection.")) }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.fail(DriverError.unreachable("The device didn't answer in time.")) }
        }
    }

    public func close() { connection.cancel() }
}
