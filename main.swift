// ShotPrompt: take a Shottr capture, start typing, and the screenshot plus
// your words open as a new T3 Code thread. The todo board's "hover a card and
// type" launcher, for screenshots.
//
// Shottr saves every capture to ~/Pictures as SCR-*.png ("Save after capture" on).
// A new file there pops a small panel by the mouse. The panel is
// non-activating: it takes the keyboard without bringing this app forward, so
// no Accessibility or Input Monitoring permission is needed. Enter sends the
// prompt through `t3-dispatch --image`; Esc, a Cmd/Ctrl shortcut on an empty
// prompt, or 5 seconds without typing closes it.

import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
let env = ProcessInfo.processInfo.environment
let captureDir = URL(fileURLWithPath: env["SHOT_PROMPT_CAPTURE_DIR"] ?? home.appendingPathComponent("Pictures").path)
let dispatchBin = env["SHOT_PROMPT_DISPATCH"] ?? home.appendingPathComponent(".local/bin/t3-dispatch").path
// The project folder the new thread opens in.
let threadCwd = env["SHOT_PROMPT_CWD"] ?? home.path
let idleSeconds: TimeInterval = 5

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Controller: NSObject, NSTextFieldDelegate {
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var panel: PromptPanel?
    private var field: NSTextField?
    private var status: NSTextField?
    private var image: URL?
    private var idleTimer: Timer?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    func start() {
        known = Set(listCaptures())
        let fd = open(captureDir.path, O_EVTONLY)
        guard fd >= 0 else { fatalError("cannot watch \(captureDir.path)") }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func listCaptures() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: captureDir.path)) ?? []
        // Shottr's "Auto" format saves photos-heavy captures as JPEG.
        let types = [".png", ".jpg", ".jpeg"]
        return names.filter { name in
            name.hasPrefix("SCR-") && types.contains { name.lowercased().hasSuffix($0) }
        }
    }

    private func scan() {
        let current = Set(listCaptures())
        let added = current.subtracting(known)
        known = current
        guard let name = added.sorted().last else { return }
        waitUntilWritten(captureDir.appendingPathComponent(name), lastSize: -1, tries: 0)
    }

    // Shottr can still be writing when the directory event fires.
    private func waitUntilWritten(_ url: URL, lastSize: Int, tries: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0 && size == lastSize || tries > 20 {
            if size > 0 { show(url) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.waitUntilWritten(url, lastSize: size, tries: tries + 1)
        }
    }

    private func show(_ url: URL) {
        dismiss()
        image = url
        let width: CGFloat = 420, thumb: CGFloat = 64
        let p = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: thumb + 20),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSVisualEffectView(frame: p.contentView!.bounds)
        content.material = .hudWindow
        content.state = .active
        content.autoresizingMask = [.width, .height]
        p.contentView = content

        let iv = NSImageView(frame: NSRect(x: 10, y: 10, width: thumb, height: thumb))
        iv.image = NSImage(contentsOf: url)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        content.addSubview(iv)

        let x = thumb + 20, w = width - x - 12
        let f = NSTextField(frame: NSRect(x: x, y: 34, width: w, height: 26))
        f.placeholderString = "Type to ask Claude about this capture"
        f.font = .systemFont(ofSize: 15)
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = self
        content.addSubview(f)

        let s = NSTextField(labelWithString: "↩ new T3 thread · esc dismiss")
        s.frame = NSRect(x: x, y: 12, width: w, height: 16)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        content.addSubview(s)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        var origin = NSPoint(x: mouse.x - width / 2, y: mouse.y - p.frame.height - 24)
        let vis = screen.visibleFrame
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - width - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - p.frame.height - 8)
        p.setFrameOrigin(origin)

        panel = p; field = f; status = s
        p.orderFrontRegardless()
        p.makeKey()
        p.makeFirstResponder(f)

        // Cmd/Ctrl before any typing means the capture was meant for something
        // else (Cmd+V into another app): get out of the way.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }
            let mods = event.modifierFlags.intersection([.command, .control])
            if !mods.isEmpty && (self.field?.stringValue.isEmpty ?? true) {
                self.dismiss()
                return nil
            }
            return event
        }
        // Switching apps means the capture was not for Claude: never let the
        // panel keep the keyboard behind another app.
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in self?.dismiss() }
        armIdle()
    }

    private func armIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) { [weak self] _ in
            guard let self, self.field?.stringValue.isEmpty ?? true else { return }
            self.dismiss()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        idleTimer?.invalidate()
        if field?.stringValue.isEmpty ?? true { armIdle() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { send(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        return false
    }

    private func send() {
        guard let url = image, let f = field else { return }
        let prompt = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        f.isEditable = false
        status?.stringValue = "launching…"
        DispatchQueue.global().async {
            let (ok, out) = dispatch(prompt: prompt, image: url)
            DispatchQueue.main.async {
                if ok {
                    self.status?.stringValue = "✓ launched in T3"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.dismiss() }
                } else {
                    f.isEditable = true
                    self.status?.stringValue = "failed: " + out
                    self.status?.textColor = .systemRed
                    NSLog("ShotPrompt dispatch failed: %@", out)
                }
            }
        }
    }

    private func dismiss() {
        idleTimer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        activationObserver = nil; resignObserver = nil
        panel?.orderOut(nil)
        panel = nil; field = nil; status = nil; image = nil
    }
}

func dispatch(prompt: String, image: URL) -> (Bool, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: dispatchBin)
    task.arguments = ["--cwd", threadCwd, "--image", image.path, prompt]
    // A LaunchAgent starts with a bare PATH; t3-dispatch needs node and git.
    var childEnv = env
    childEnv["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    task.environment = childEnv
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return (false, error.localizedDescription) }
    task.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (task.terminationStatus == 0, out)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
