import Cocoa
import ApplicationServices

private let focusChangedCallback: AXObserverCallback = { _, element, _, userData in
    guard let userData = userData else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(userData).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    DispatchQueue.main.async {
        tracker.recordFocus(for: pid)
    }
}

final class FocusTracker {
    private struct Entry {
        let pid: pid_t
        let window: AXUIElement
    }

    private var lastFocusedByDisplay: [CGDirectDisplayID: Entry] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    // After we activate or raise a window in pid X, that app frequently emits its own
    // focus-change notifications as it settles (e.g. Chrome auto-flipping its main window).
    // Ignore recordFocus from X for a short window so those knock-on events don't overwrite
    // entries that the user genuinely set by clicking.
    private var suppressUntil: [pid_t: Date] = [:]
    private let suppressionDuration: TimeInterval = 0.5

    private let logPath = "/tmp/autofocusmonitor.log"
    private func log(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    private func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid\(pid)"
    }

    private func logDisplayLayout() {
        // Dump all CGDisplays with bounds.
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        for i in 0..<Int(count) {
            let id = ids[i]
            let b = CGDisplayBounds(id)
            log("CGDisplay \(id): bounds=(\(b.origin.x),\(b.origin.y) \(b.size.width)x\(b.size.height))")
        }
        // Dump NSScreens with their reported NSScreenNumber so we can spot mismatches.
        for (i, screen) in NSScreen.screens.enumerated() {
            let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            log("NSScreen[\(i)] NSScreenNumber=\(n) frame=(\(screen.frame.origin.x),\(screen.frame.origin.y) \(screen.frame.size.width)x\(screen.frame.size.height))")
        }
    }

    private func windowTitle(_ window: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref)
        return (ref as? String) ?? "(no title)"
    }

    func start() {
        logDisplayLayout()
        for runningApp in NSWorkspace.shared.runningApplications where runningApp.activationPolicy == .regular {
            attachObserver(for: runningApp.processIdentifier)
            recordFocus(for: runningApp.processIdentifier)
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.attachObserver(for: app.processIdentifier)
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.detachObserver(for: app.processIdentifier)
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.recordFocus(for: app.processIdentifier)
            }
        }
    }

    private func attachObserver(for pid: pid_t) {
        guard observers[pid] == nil, pid > 0 else { return }
        var observer: AXObserver?
        let result = AXObserverCreate(pid, focusChangedCallback, &observer)
        guard result == .success, let obs = observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, appElement, kAXMainWindowChangedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, appElement, kAXWindowMovedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }

    private func detachObserver(for pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        for (k, v) in lastFocusedByDisplay where v.pid == pid {
            lastFocusedByDisplay.removeValue(forKey: k)
        }
    }

    func recordFocus(for pid: pid_t) {
        if let until = suppressUntil[pid], Date() < until {
            log("    recordFocus suppressed for \(appName(pid))")
            return
        }
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard res == .success, let win = winRef else { return }
        let window = win as! AXUIElement
        guard let displayID = displayID(for: window) else { return }

        // The same window can only live on one display. Drop any stale references
        // to this window that other displays may be holding (e.g. user dragged it across).
        let staleKeys = lastFocusedByDisplay.compactMap { (k, v) -> CGDirectDisplayID? in
            (k != displayID && CFEqual(v.window, window)) ? k : nil
        }
        for k in staleKeys {
            lastFocusedByDisplay.removeValue(forKey: k)
        }

        lastFocusedByDisplay[displayID] = Entry(pid: pid, window: window)
    }

    private func validatedEntry(for displayID: CGDirectDisplayID) -> Entry? {
        guard let entry = lastFocusedByDisplay[displayID] else { return nil }
        guard isWindowAlive(entry.window),
              self.displayID(for: entry.window) == displayID else {
            lastFocusedByDisplay.removeValue(forKey: displayID)
            return nil
        }
        return entry
    }

    func activateLastWindow(on displayID: CGDirectDisplayID) {
        log("==> cross to display \(displayID); known entries: \(lastFocusedByDisplay.map { "\($0.key)=>\(appName($0.value.pid)):'\(windowTitle($0.value.window))'" }.joined(separator: ", "))")
        var activatedPid: pid_t? = nil
        if let entry = validatedEntry(for: displayID) {
            let alreadyActive: Bool = {
                guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == entry.pid else { return false }
                guard let frontWin = focusedWindow(of: entry.pid) else { return false }
                return CFEqual(frontWin, entry.window)
            }()
            log("    entry=\(appName(entry.pid)):'\(windowTitle(entry.window))' alreadyActive=\(alreadyActive)")
            if !alreadyActive {
                bringWindowForward(pid: entry.pid, window: entry.window)
                activatedPid = entry.pid
            }
        } else if let pid = activateTopmostWindow(on: displayID) {
            log("    no entry; topmost-fallback activated \(appName(pid))")
            activatedPid = pid
        } else {
            log("    no entry and no topmost on display \(displayID)")
        }

        // Activating an app raises ALL of its windows globally. If that app has windows
        // on other displays, those windows will cover whatever was frontmost there. Only
        // in that case do we need to re-raise the other displays' recorded windows.
        if let pid = activatedPid {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.restoreOtherDisplays(except: displayID, displacedBy: pid)
            }
        }
    }

    private func restoreOtherDisplays(except activeDisplay: CGDirectDisplayID, displacedBy activatedPid: pid_t) {
        log("    restoreOtherDisplays except=\(activeDisplay) activated=\(appName(activatedPid))")
        let otherIDs = lastFocusedByDisplay.keys.filter { $0 != activeDisplay }
        for otherID in otherIDs {
            guard let recorded = lastFocusedByDisplay[otherID] else {
                log("      [\(otherID)] no entry; skip"); continue
            }
            if recorded.pid == activatedPid {
                log("      [\(otherID)] same-app (\(appName(recorded.pid))); skip")
                continue
            }
            let hasWin = appHasWindow(pid: activatedPid, on: otherID)
            if !hasWin {
                log("      [\(otherID)] activated app has no window here; skip")
                continue
            }
            if let entry = validatedEntry(for: otherID) {
                log("      [\(otherID)] raising \(appName(entry.pid)):'\(windowTitle(entry.window))'")
                suppressUntil[entry.pid] = Date().addingTimeInterval(suppressionDuration)
                AXUIElementPerformAction(entry.window, kAXRaiseAction as CFString)
            } else {
                log("      [\(otherID)] entry stale after validation; dropped")
            }
        }
    }

    private func bringWindowForward(pid: pid_t, window: AXUIElement) {
        log("    bringWindowForward \(appName(pid)):'\(windowTitle(window))'")
        suppressUntil[pid] = Date().addingTimeInterval(suppressionDuration)
        // Apps with multiple windows (Chrome, VS Code/Electron, etc.) often keep their own
        // "main window" state and ignore a bare kAXRaiseAction — activate() then makes the
        // app's previously-remembered main window key, not the one we want. We set
        // kAXFocusedWindow + kAXMainWindow on the app element AND kAXMain + kAXFocused on
        // the window itself so the app has no ambiguity about which window we mean.
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private func appHasWindow(pid: pid_t, on displayID: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(displayID)
        let infoList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in infoList {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let wPid = w[kCGWindowOwnerPID as String] as? pid_t, wPid == pid else { continue }
            guard let bDict = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bDict["X"] ?? 0, y: bDict["Y"] ?? 0,
                              width: bDict["Width"] ?? 0, height: bDict["Height"] ?? 0)
            if bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func activateTopmostWindow(on displayID: CGDirectDisplayID) -> pid_t? {
        let bounds = CGDisplayBounds(displayID)
        let infoList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in infoList {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bDict = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bDict["X"] ?? 0, y: bDict["Y"] ?? 0,
                              width: bDict["Width"] ?? 0, height: bDict["Height"] ?? 0)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if bounds.contains(center) {
                if let pid = w[kCGWindowOwnerPID as String] as? pid_t {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                    return pid
                }
            }
        }
        return nil
    }

    private func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard res == .success, let w = winRef else { return nil }
        return (w as! AXUIElement)
    }

    private func isWindowAlive(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
    }

    private func displayID(for window: AXUIElement) -> CGDirectDisplayID? {
        // AX position/size are in CG coords (top-left origin, main display at 0,0) — same as CGDisplayBounds.
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        let rect = CGRect(origin: pos, size: size)

        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let result = CGGetDisplaysWithRect(rect, 16, &displays, &count)
        if result == .success && count > 0 {
            return displays[0]
        }
        return nil
    }
}
