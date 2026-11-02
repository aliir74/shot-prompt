import Foundation

// Shottr names captures SCR-*; its "Auto" format saves photo-heavy ones as JPEG.
public func isCapture(_ name: String) -> Bool {
    let types = [".png", ".jpg", ".jpeg"]
    return name.hasPrefix("SCR-") && types.contains { name.lowercased().hasSuffix($0) }
}

public func listCaptures(in dir: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter(isCapture)
}

// The newest capture that was not there before, if any.
public func newestCapture(current: Set<String>, known: Set<String>) -> String? {
    current.subtracting(known).max()
}

public enum WriteCheck: Equatable {
    case ready, giveUp, retry
}

// Shottr can still be writing when the directory event fires: a file is
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

// Watches the capture folder and calls onCapture once a new capture is fully written.
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
        known = Set(listCaptures(in: directory))
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
        let current = Set(listCaptures(in: directory))
        let added = newestCapture(current: current, known: known)
        known = current
        guard let name = added else { return }
        waitUntilWritten(directory.appendingPathComponent(name), lastSize: -1, tries: 0)
    }

    func waitUntilWritten(_ url: URL, lastSize: Int, tries: Int) {
        let size = fileSize(url)
        switch writeCheck(size: size, lastSize: lastSize, tries: tries, maxTries: maxTries) {
        case .ready:
            onCapture(url)
        case .giveUp:
            return
        case .retry:
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                self.waitUntilWritten(url, lastSize: size, tries: tries + 1)
            }
        }
    }
}
