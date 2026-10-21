import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import LumaBarCore

/// Mirrors the average colour of the main display onto the bulbs.
///
/// Bulbs are slow and UDP is lossy, so this is deliberately gentle: a tiny capture, smoothing,
/// at most ~3 updates a second, and nothing is sent unless the colour changed noticeably.
@MainActor
final class ScreenSyncAutomation: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published private(set) var status = "Off"

    private let store: BulbStore
    private let arbiter: AutomationArbiter
    private var stream: SCStream?
    private var running = false
    private let queue = DispatchQueue(label: "LumaBar.ScreenSync")
    private let sampler = ColorSampler()

    init(store: BulbStore, arbiter: AutomationArbiter) {
        self.store = store
        self.arbiter = arbiter
    }

    func start() {
        guard !running else { return }
        running = true
        Task { await begin() }
    }

    func stop() {
        running = false
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        arbiter.end("screen")
        status = "Off"
    }

    private func begin() async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            status = "Needs Screen Recording permission. Allow LumaBar in System Settings ▸ Privacy & Security, then turn this off and on."
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { status = "No display found."; return }

            let config = SCStreamConfiguration()
            config.width = 64                       // a thumbnail is all an average needs
            config.height = 36
            config.minimumFrameInterval = CMTime(value: 1, timescale: 4)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 3

            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            guard running else { return }
            try await stream.startCapture()
            self.stream = stream
            status = "Mirroring your screen."
            // Take a claim so the original light is restored when this stops; frames apply themselves.
            await arbiter.begin("screen", priority: AutomationArbiter.Priority.screenSync) {}
        } catch {
            status = "Couldn't start screen capture: \(error.localizedDescription)"
            running = false
        }
    }

    // MARK: SCStreamOutput (runs on `queue`)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let params = sampler.process(pixels) else { return }
        Task { @MainActor [weak self] in
            guard let self, running, arbiter.allows(priority: AutomationArbiter.Priority.screenSync) else { return }
            store.sendToAll(params)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.status = "Screen capture stopped: \(error.localizedDescription)"
            self?.running = false
        }
    }
}

/// Averages frames, smooths them and decides when a new colour is worth sending. Only touched from the capture queue.
private final class ColorSampler: @unchecked Sendable {
    private var smoothed: (r: Double, g: Double, b: Double)?
    private var lastSent: (r: Double, g: Double, b: Double)?
    private var lastSentAt = Date.distantPast

    private let smoothing = 0.5                  // weight of the newest frame
    private let minInterval: TimeInterval = 0.35 // ~3 updates per second at most
    private let minChange = 14.0                 // of 255, summed over channels

    func process(_ buffer: CVPixelBuffer) -> LightCommand? {
        guard let average = Self.averageColor(of: buffer) else { return nil }

        let s = smoothed.map {
            (r: $0.r + (average.r - $0.r) * smoothing, g: $0.g + (average.g - $0.g) * smoothing, b: $0.b + (average.b - $0.b) * smoothing)
        } ?? average
        smoothed = s

        let now = Date()
        guard now.timeIntervalSince(lastSentAt) >= minInterval else { return nil }
        if let last = lastSent, abs(s.r - last.r) + abs(s.g - last.g) + abs(s.b - last.b) < minChange { return nil }

        lastSent = s
        lastSentAt = now
        return ColorMath.screenParams(r: s.r, g: s.g, b: s.b)
    }

    private static func averageColor(of buffer: CVPixelBuffer) -> (r: Double, g: Double, b: Double)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }

        var r = 0.0, g = 0.0, b = 0.0
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                b += Double(row[x * 4]); g += Double(row[x * 4 + 1]); r += Double(row[x * 4 + 2]) // BGRA
            }
        }
        let n = Double(width * height)
        return (r / n, g / n, b / n)
    }
}
