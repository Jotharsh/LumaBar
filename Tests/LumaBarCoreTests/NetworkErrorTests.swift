import XCTest
import Network
@testable import LumaBarCore

final class NetworkErrorTests: XCTestCase {
    func testNoRouteToHostIsTreatedAsMacOSBlockingTheLocalNetwork() {
        XCTAssertTrue(NetworkErrors.isLocalNetworkBlock(NWError.posix(.EHOSTUNREACH)))
        XCTAssertTrue(NetworkErrors.isLocalNetworkBlock(POSIXError(.EHOSTUNREACH)))
        XCTAssertTrue(NetworkErrors.isLocalNetworkBlock(NSError(domain: NSPOSIXErrorDomain, code: 65)))
    }

    func testTheErrorIsFoundEvenWhenWrappedByURLSession() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: 65)
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertTrue(NetworkErrors.isLocalNetworkBlock(wrapped))
    }

    func testOrdinaryFailuresAreNotBlamedOnMacOS() {
        XCTAssertFalse(NetworkErrors.isLocalNetworkBlock(NWError.posix(.ECONNREFUSED)))
        XCTAssertFalse(NetworkErrors.isLocalNetworkBlock(NWError.posix(.ETIMEDOUT)))
        XCTAssertFalse(NetworkErrors.isLocalNetworkBlock(URLError(.timedOut)))
        XCTAssertFalse(NetworkErrors.isLocalNetworkBlock(WizError.timeout))
    }

    func testClassifyProducesTheRightDriverError() {
        guard case .localNetworkBlocked(let message) = NetworkErrors.classify(NWError.posix(.EHOSTUNREACH)) else { return XCTFail() }
        XCTAssertTrue(message.contains("blocking LumaBar"))
        guard case .unreachable = NetworkErrors.classify(NWError.posix(.ECONNREFUSED)) else { return XCTFail() }
        XCTAssertEqual(NetworkErrors.classify(DriverError.rejected("x")), .rejected("x"), "driver errors pass through unchanged")
    }

    func testWizBlockedErrorMapsToTheDriverError() {
        guard case .localNetworkBlocked = WizDriver.translate(WizError.localNetworkBlocked) as? DriverError else { return XCTFail() }
        guard case .unreachable = WizDriver.translate(WizError.timeout) as? DriverError else { return XCTFail() }
    }
}
