import Cocoa

final class MouseDisplayMonitor {
    private var timer: Timer?
    private var lastDisplayID: CGDirectDisplayID = 0
    private let onCross: (CGDirectDisplayID) -> Void

    init(onCross: @escaping (CGDirectDisplayID) -> Void) {
        self.onCross = onCross
    }

    func start() {
        lastDisplayID = currentMouseDisplayID() ?? 0
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Don't fire cross events while any mouse button is held — the user is dragging
        // a window or selecting across displays, and an activation would steal focus and
        // interrupt the drag. Resumes naturally on button release at the next tick.
        if NSEvent.pressedMouseButtons != 0 { return }

        guard let id = currentMouseDisplayID() else { return }
        if id != lastDisplayID && lastDisplayID != 0 {
            lastDisplayID = id
            onCross(id)
        } else {
            lastDisplayID = id
        }
    }

    private func currentMouseDisplayID() -> CGDirectDisplayID? {
        // Use CG coords (top-left origin) so cursor and window display lookups share
        // the same CGDirectDisplayID namespace as CGGetDisplaysWithRect — important on
        // setups with USB / DisplayLink monitors where NSScreen mapping can drift.
        guard let cgLoc = CGEvent(source: nil)?.location else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(cgLoc, 16, &displays, &count)
        return (result == .success && count > 0) ? displays[0] : nil
    }
}
