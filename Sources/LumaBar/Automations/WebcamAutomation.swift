import CoreMediaIO
import Foundation
import LumaBarCore

/// Switches to the "Video Call" preset while any camera is in use, then restores the light.
@MainActor
final class WebcamAutomation: ObservableObject {
    @Published private(set) var status = "Off"

    private let store: BulbStore
    private let arbiter: AutomationArbiter
    private var timer: Timer?
    private var running = false
    private var active = false
    private var idleTicks = 0

    /// The camera must be off for this many consecutive checks before the light is restored,
    /// so a call that briefly toggles video doesn't make the light flicker.
    private let idleTicksBeforeRestore = 3

    init(store: BulbStore, arbiter: AutomationArbiter) {
        self.store = store
        self.arbiter = arbiter
    }

    func start() {
        guard !running else { return }
        running = true
        status = "On. Waiting for a camera to turn on."
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        if active { arbiter.end("webcam"); active = false }
        status = "Off"
    }

    private func tick() {
        guard running else { return }
        if CameraMonitor.isAnyCameraRunning() {
            idleTicks = 0
            guard !active else { return }
            active = true
            status = "Camera in use: Video Call preset applied."
            let preset = store.presets.first { $0.id == Preset.videoCallID } ?? Preset.defaults.last!
            Task {
                await arbiter.begin("webcam", priority: AutomationArbiter.Priority.webcam) { [store] in store.sendToAll(preset.command) }
                // The camera may have turned off while the original light state was being captured.
                if !active { arbiter.end("webcam") }
            }
        } else if active {
            idleTicks += 1
            if idleTicks >= idleTicksBeforeRestore {
                active = false
                idleTicks = 0
                status = "On. Waiting for a camera to turn on."
                arbiter.end("webcam")
            }
        }
    }
}

enum CameraMonitor {
    /// True if any video capture device is being used by any process. Reading this doesn't need camera permission.
    static func isAnyCameraRunning() -> Bool {
        func address(_ selector: Int) -> CMIOObjectPropertyAddress {
            CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        }

        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var devicesAddress = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == 0, size > 0 else { return false }

        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &devicesAddress, 0, nil, size, &used, &devices) == 0 else { return false }

        for device in devices {
            var runningAddress = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var isRunning: UInt32 = 0
            var runningUsed: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &runningUsed, &isRunning)
            if status == 0, isRunning != 0 { return true }
        }
        return false
    }
}
