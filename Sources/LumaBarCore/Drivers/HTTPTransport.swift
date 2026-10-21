import Foundation

/// The seam HTTP-based drivers (Hue, Home Assistant) talk through, so tests can swap in a mock.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 4) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DriverError.protocolError("Not an HTTP response.") }
            return (data, http)
        } catch let error as DriverError {
            throw error
        } catch {
            throw DriverError.unreachable(error.localizedDescription)
        }
    }
}
