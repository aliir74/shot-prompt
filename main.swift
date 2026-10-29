// ShotPrompt: take a Shottr capture, start typing, and the screenshot plus
// your words open as a new T3 Code thread. The todo board's "hover a card and
// type" launcher, for screenshots.
//
// Shottr saves every capture to ~/Pictures as SCR-*.png ("Save after capture" on).
// A new file there pops a small panel by the mouse. The panel is
// non-activating: it takes the keyboard without bringing this app forward, so
// no Accessibility or Input Monitoring permission is needed. Enter sends the
// prompt through `t3-dispatch --image`. While the prompt is empty, Esc, a
// Cmd/Ctrl shortcut, switching apps, or 5 seconds idle closes it; once you
// have typed, only Esc does.

import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
let env = ProcessInfo.processInfo.environment
let captureDir = URL(fileURLWithPath: env["SHOT_PROMPT_CAPTURE_DIR"] ?? home.appendingPathComponent("Pictures").path)
let dispatchBin = env["SHOT_PROMPT_DISPATCH"] ?? home.appendingPathComponent(".local/bin/t3-dispatch").path
// The project folder the new thread opens in.
let threadCwd = env["SHOT_PROMPT_CWD"] ?? home.path
let idleSeconds: TimeInterval = 5
// The prompt grows up to this many lines, then scrolls.
let maxPromptLines: CGFloat = 6

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// NSTextView has no placeholder of its own.
final class PromptTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        (placeholder as NSString).draw(
            at: NSPoint(x: x, y: textContainerInset.height),
            withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }
}

final class Controller: NSObject, NSTextViewDelegate {
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var panel: PromptPanel?
    private var field: PromptTextView?
    private var scroll: NSScrollView?
    private var thumbnail: NSImageView?
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

    private var hasText: Bool { !(field?.string.isEmpty ?? true) }

    private func show(_ url: URL) {
        // A new capture while typing replaces the screenshot, not the prompt.
        // While a send is running, the sent screenshot stays.
        if hasText {
            if field?.isEditable == false { return }
            image = url
            thumbnail?.image = NSImage(contentsOf: url)
            return
        }
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
        let sv = NSScrollView(frame: NSRect(x: x, y: 42, width: w, height: 18))
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        // It sits under the transparent title bar; without this AppKit insets
        // its top and the last line hides behind a scroller.
        sv.automaticallyAdjustsContentInsets = false
        let f = PromptTextView(frame: NSRect(origin: .zero, size: sv.contentSize))
        f.placeholder = "Type to ask Claude about this capture"
        f.font = .systemFont(ofSize: 15)
        f.drawsBackground = false
        f.isRichText = false
        f.allowsUndo = true
        f.isAutomaticQuoteSubstitutionEnabled = false
        f.isAutomaticDashSubstitutionEnabled = false
        f.focusRingType = .none
        f.textContainerInset = .zero
        f.textContainer?.lineFragmentPadding = 0
        f.textContainer?.widthTracksTextView = true
        f.isVerticallyResizable = true
        f.isHorizontallyResizable = false
        f.autoresizingMask = [.width]
        f.minSize = NSSize(width: 0, height: 0)
        f.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        f.delegate = self
        sv.documentView = f
        content.addSubview(sv)

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

        panel = p; field = f; scroll = sv; thumbnail = iv; status = s
        fitPrompt()
        p.orderFrontRegardless()
        p.makeKey()
        p.makeFirstResponder(f)

        // Cmd/Ctrl before any typing means the capture was meant for something
        // else (Cmd+V into another app): get out of the way.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }
            let mods = event.modifierFlags.intersection([.command, .control])
            if !mods.isEmpty && !self.hasText {
                self.dismiss()
                return nil
            }
            return event
        }
        // Switching apps before typing means the capture was not for Claude.
        // After typing, keep the panel and its text; click it to keep going.
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismissIfEmpty() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in self?.dismissIfEmpty() }
        armIdle()
    }

    private func armIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) { [weak self] _ in
            self?.dismissIfEmpty()
        }
    }

    private func dismissIfEmpty() {
        if !hasText { dismiss() }
    }

    func textDidChange(_ notification: Notification) {
        idleTimer?.invalidate()
        if !hasText { armIdle() }
        field?.needsDisplay = true
        fitPrompt()
    }

    // Grow the prompt (and the panel, downward from its top edge) to fit the
    // text, up to maxPromptLines; past that the prompt scrolls.
    private func fitPrompt() {
        guard let p = panel, let f = field, let sv = scroll,
              let lm = f.layoutManager, let tc = f.textContainer, let font = f.font else { return }
        lm.ensureLayout(for: tc)
        let line = ceil(lm.defaultLineHeight(for: font))
        let h = min(max(ceil(lm.usedRect(for: tc).height), line), line * maxPromptLines)
        let top: CGFloat = 24, bottom: CGFloat = 42, thumb: CGFloat = 64
        let height = max(thumb + 20, bottom + h + top)
        if p.frame.height != height {
            var frame = p.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            if let vis = p.screen?.visibleFrame, frame.minY < vis.minY + 8 {
                frame.origin.y = vis.minY + 8
            }
            p.setFrame(frame, display: true)
        }
        sv.frame = NSRect(x: sv.frame.minX, y: height - top - h, width: sv.frame.width, height: h)
        thumbnail?.frame.origin.y = height - 10 - thumb
        f.scrollRangeToVisible(f.selectedRange())
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { send(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        return false
    }

    private func send() {
        guard let url = image, let f = field else { return }
        let prompt = f.string.trimmingCharacters(in: .whitespacesAndNewlines)
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
        panel = nil; field = nil; scroll = nil; thumbnail = nil; status = nil; image = nil
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
