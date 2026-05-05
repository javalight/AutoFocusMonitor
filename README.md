# AutoFocusMonitor

A small macOS menu bar app that auto-focuses the right window when you move your mouse to a different monitor.

On macOS, multi-monitor focus is click-driven: even if your cursor is on another display, keyboard input still goes to whatever app you last clicked. AutoFocusMonitor fixes that for users who think per-monitor instead of per-window — when your cursor crosses to another display, it raises and activates the window you were last using on that display.

## How it differs from AutoRaise

[AutoRaise](https://github.com/sbmpost/AutoRaise) implements *focus-follows-mouse on individual windows*: hover over any window and it gets focus. That's powerful but easy to trigger by accident.

AutoFocusMonitor only acts at **display boundaries**. It remembers the last window you used on each monitor and restores that window when your cursor returns there — regardless of which window your cursor happens to be over. No accidental focus changes while you move within a single display.

## Install

1. Download `AutoFocusMonitor.dmg` from the [Releases](../../releases) page.
2. Open the DMG and drag `AutoFocusMonitor.app` to `/Applications`.
3. Because the app isn't signed with an Apple Developer ID, macOS Gatekeeper will block the first launch. To bypass:
   - Right-click `AutoFocusMonitor.app` → **Open** → **Open** in the dialog. *(or)*
   - System Settings → **Privacy & Security** → scroll to "AutoFocusMonitor was blocked..." → **Open Anyway**.
4. On first launch, macOS will prompt for **Accessibility** permission. Grant it in System Settings → **Privacy & Security** → **Accessibility**, and toggle `AutoFocusMonitor` on. The running app picks up the grant within a couple seconds — no relaunch needed.

A `🖥` icon appears in the menu bar. The menu has an Enabled toggle and Quit.

## Usage

That's it — move your mouse between monitors. The last-focused window on each display reactivates as you go.

To toggle the behavior off temporarily, click the menu bar icon and uncheck **Enabled**.

## How it works

- Per-app `AXObserver`s track focus changes (`kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`, `kAXWindowMovedNotification`) and `NSWorkspace.didActivateApplicationNotification` covers app switches.
- A `displayID → (pid, AXUIElement)` map records the last-focused window per display.
- A 50 ms timer polls `NSEvent.mouseLocation` and fires when the cursor's `CGDirectDisplayID` changes.
- On a crossing, the new display's last window is raised via `kAXRaiseAction` and its app is activated. Each *other* display's last window is then re-raised (without activating its app) so per-display visual state is preserved when an activated app has windows on multiple monitors.

## Build from source

Requires Xcode Command Line Tools.

```sh
./build.sh                    # builds AutoFocusMonitor.app
./make-dmg.sh                 # builds the .app and packages it into dist/AutoFocusMonitor.dmg
```

The build script ad-hoc signs the binary with `codesign --sign -`, which is enough to run locally but produces the Gatekeeper warning on other machines. To ship a smoother experience, sign with a Developer ID certificate before distributing.

## Limitations

- Sandbox-incompatible. Cross-app Accessibility APIs are blocked in the App Store sandbox, so this can't ship on the Mac App Store. Direct distribution only.
- Some apps resist programmatic activation; the `kAXRaiseAction` + `NSRunningApplication.activate()` pair is the most reliable combo without private APIs.
- After a rebuild, the ad-hoc signature changes and macOS may invalidate the existing Accessibility grant. Re-add the rebuilt app to the Accessibility list. (Not an issue for end users who download the released DMG and don't rebuild.)

## License

[MIT](LICENSE)
