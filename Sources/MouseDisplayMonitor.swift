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
        guard let id = currentMouseDisplayID() else { return }
        if id != lastDisplayID && lastDisplayID != 0 {
            FileHandle.standardError.write(Data("[mma] cursor crossed: \(lastDisplayID) -> \(id)\n".utf8))
            lastDisplayID = id
            onCross(id)
        } else {
            lastDisplayID = id
        }
    }

    private func currentMouseDisplayID() -> CGDirectDisplayID? {
        let loc = NSEvent.mouseLocation // Cocoa coords (origin bottom-left, primary screen)
        for screen in NSScreen.screens {
            if NSPointInRect(loc, screen.frame) {
                if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    return CGDirectDisplayID(num.uint32Value)
                }
            }
        }
        return nil
    }
}
