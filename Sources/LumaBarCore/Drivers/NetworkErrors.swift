import Foundation
import Network

enum NetworkErrors {
    /// "No route to host" (EHOSTUNREACH) from a device that is on your own network is what macOS reports
    /// when an app has been refused the Local Network permission. A bulb that is genuinely off doesn't
    /// look like this (it times out instead), so this is a strong hint rather than a certainty.
    static func isLocalNetworkBlock(_ error: Error) -> Bool {
        if let nw = error as? NWError, case .posix(let code) = nw { return code == .EHOSTUNREACH }
        if let posix = error as? POSIXError { return posix.code == .EHOSTUNREACH }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EHOSTUNREACH) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isLocalNetworkBlock(underlying) }
        return false
    }

    /// Turns a low-level network error into the driver error that best describes it.
    static func classify(_ error: Error) -> DriverError {
        if let driverError = error as? DriverError { return driverError }
        if isLocalNetworkBlock(error) {
            return .localNetworkBlocked("macOS is blocking LumaBar from reaching devices on your local network (\(error.localizedDescription)).")
        }
        return .unreachable(error.localizedDescription)
    }
}
