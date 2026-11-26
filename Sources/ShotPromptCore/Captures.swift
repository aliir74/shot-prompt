import CoreGraphics
import Foundation

// macOS tags every screenshot file with this extended attribute: its own
// Cmd+Shift+3/4/5 captures, and tools that save like it (Shottr does).
public let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
// macOS's own captures also say where on screen they were: [x, y, width,
// height] in points, top-left origin across all screens.
public let screenCaptureRectAttribute = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
// A screenshot older than this when it shows up was moved or copied in, not just taken.
public let captureMaxAge: TimeInterval = 60

// An image file that is not hidden: macOS writes a capture under a hidden
// ".Screenshot…" name first, then renames it. HEIC is macOS's HDR capture format.
public func isImageName(_ name: String) -> Bool {
    let types = [".png", ".jpg", ".jpeg", ".heic"]
    return !name.hasPrefix(".") && types.contains { name.lowercased().hasSuffix($0) }
}

// The value of an extended attribute, or nil when the file has none.
public func extendedAttribute(_ name: String, of url: URL) -> Data? {
    let size = getxattr(url.path, name, nil, 0, 0, 0)
    guard size >= 0 else { return nil }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
    return read == size ? data : nil
}

// A screenshot: Shottr's SCR-* name (its "Auto" format saves photo-heavy
// ones as JPEG), or any image tagged as a screen capture.
public func isCapture(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard isImageName(name) else { return false }
    return name.hasPrefix("SCR-") || extendedAttribute(screenCaptureAttribute, of: url) != nil
}

// Where a macOS capture was, from its rect attribute; nil for other tools.
public func captureRect(attribute data: Data?) -> CGRect? {
    guard let data,
          let v = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Double],
          v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
}

public func creationDate(_ url: URL) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
}

// Whether a file was made recently enough to be a capture just taken.
public func isFresh(created: Date?, now: Date) -> Bool {
    guard let created else { return false }
    return now.timeIntervalSince(created) < captureMaxAge
}

public func listImages(in dir: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter(isImageName)
}

// The images that were not there before.
public func newImages(current: Set<String>, known: Set<String>) -> [String] {
    current.subtracting(known).sorted()
}

// Where macOS saves screenshots: the screencapture "location" setting
// (`defaults read com.apple.screencapture location`), else the Desktop.
public func screenshotFolder(location: String?, home: URL) -> URL {
    guard let loc = location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty else {
        return home.appendingPathComponent("Desktop")
    }
    let expanded = loc.hasPrefix("~") ? home.path + loc.dropFirst() : loc
    return URL(fileURLWithPath: expanded)
}

// Each folder once, in order, by its standardized path.
public func uniqueFolders(_ folders: [URL]) -> [URL] {
    var seen = Set<String>()
    return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
}

public enum WriteCheck: Equatable {
    case ready, giveUp, retry
}

// The tool can still be writing when the directory event fires: a file is
// ready once its size is non-zero and the same twice in a row. After
// maxTries it is taken as it is, or dropped if still empty.
public func writeCheck(size: Int, lastSize: Int, tries: Int, maxTries: Int) -> WriteCheck {
    guard size > 0 && size == lastSize || tries > maxTries else { return .retry }
    return size > 0 ? .ready : .giveUp
}

public func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

public enum WatchError: Error, Equatable {
    case cannotOpen(String)
}

// Watches a folder and calls onCapture once a new screenshot is fully written.
public final class CaptureWatcher {
    public let directory: URL
    public var onCapture: (URL) -> Void = { _ in }
    let pollInterval: TimeInterval
    let maxTries: Int
    var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?

    public init(directory: URL, pollInterval: TimeInterval = 0.15, maxTries: Int = 20) {
        self.directory = directory
        self.pollInterval = pollInterval
        self.maxTries = maxTries
    }

    public func start() throws {
        known = Set(listImages(in: directory))
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { throw WatchError.cannotOpen(directory.path) }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    func scan() {
        let current = Set(listImages(in: directory))
        let added = newImages(current: current, known: known)
        known = current
        for name in added {
            waitUntilWritten(directory.appendingPathComponent(name), lastSize: -1, tries: 0)
        }
    }

    func waitUntilWritten(_ url: URL, lastSize: Int, tries: Int) {
        let size = fileSize(url)
        switch writeCheck(size: size, lastSize: lastSize, tries: tries, maxTries: maxTries) {
        case .ready:
            // Checked once written: a tool may tag the file after the bytes land.
            if isCapture(url) && isFresh(created: creationDate(url), now: Date()) { onCapture(url) }
        case .giveUp:
            return
        case .retry:
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                self.waitUntilWritten(url, lastSize: size, tries: tries + 1)
            }
        }
    }
}
