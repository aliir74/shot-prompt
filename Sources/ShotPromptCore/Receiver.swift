import Foundation

// The phone receiver: an opt-in HTTP endpoint on 127.0.0.1 that an iPhone
// shortcut reaches through `tailscale serve`. `GET /projects` lists the picker's
// project names; `POST /shot` (multipart form: image, prompt, optional project)
// saves the image and runs the same dispatch command as the prompt panel.
// Both need `Authorization: Bearer <receiverToken>`. See ios/README.md.

// UserDefaults keys. The receiver runs only when both are set.
public let receiverPortKey = "receiverPort"
public let receiverTokenKey = "receiverToken"

// Largest request body accepted. An iPhone 16 Pro Max screenshot is about 5 MB.
public let maxReceiverBody = 25 * 1024 * 1024
// Largest header block accepted before the blank line.
let maxHeaderBytes = 64 * 1024

// The port and token to serve with, or nil when the receiver is off.
public func receiverSettings(port: Int, token: String?) -> (port: UInt16, token: String)? {
    guard (1...65535).contains(port), let token, !token.isEmpty else { return nil }
    return (UInt16(port), token)
}

public struct HTTPRequest: Equatable {
    public let method: String
    public let path: String
    // Header names lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum ParseResult: Equatable {
    case incomplete
    case bad
    case tooLarge
    case done(HTTPRequest)
}

let crlfcrlf = Data("\r\n\r\n".utf8)

// Parses one HTTP/1.1 request from the bytes read so far.
public func parseRequest(_ buffer: Data, maxBody: Int = maxReceiverBody) -> ParseResult {
    guard let end = buffer.range(of: crlfcrlf) else {
        return buffer.count > maxHeaderBytes ? .bad : .incomplete
    }
    guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad }
    var lines = head.components(separatedBy: "\r\n")
    let start = lines.removeFirst().split(separator: " ")
    guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .bad }
    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { return .bad }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
    }
    if headers["transfer-encoding"] != nil { return .bad }
    var length = 0
    if let value = headers["content-length"] {
        guard let n = Int(value), n >= 0 else { return .bad }
        length = n
    }
    if length > maxBody { return .tooLarge }
    let body = buffer[end.upperBound...]
    if body.count < length { return .incomplete }
    // Drop any query string; the routes take none.
    let path = String(start[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    return .done(HTTPRequest(method: String(start[0]), path: path, headers: headers,
                             body: Data(body.prefix(length))))
}

public struct HTTPResponse: Equatable {
    public let status: Int
    public let contentType: String
    public let body: Data

    public init(status: Int, text: String) {
        self.status = status
        contentType = "text/plain; charset=utf-8"
        body = Data(text.utf8)
    }

    public init(status: Int, json: Data) {
        self.status = status
        contentType = "application/json"
        body = json
    }

    static let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                          405: "Method Not Allowed", 413: "Payload Too Large",
                          415: "Unsupported Media Type", 502: "Bad Gateway"]

    // The bytes on the wire. Every response closes the connection.
    public func serialized() -> Data {
        let head = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "Error")\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

public struct FormPart: Equatable {
    public let name: String
    public let filename: String?
    public let data: Data
}

// The parts of a multipart/form-data body, or nil when it is not one.
public func parseMultipart(body: Data, contentType: String) -> [FormPart]? {
    guard contentType.lowercased().hasPrefix("multipart/form-data"),
          let b = contentType.components(separatedBy: ";").lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix("boundary=") })
    else { return nil }
    let boundary = String(b.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    guard !boundary.isEmpty else { return nil }
    let delimiter = Data("--\(boundary)".utf8)
    var parts: [FormPart] = []
    var cursor = body.startIndex
    guard let first = body.range(of: delimiter, in: cursor..<body.endIndex) else { return nil }
    cursor = first.upperBound
    // "--" after a delimiter ends the body.
    while !body[cursor...].starts(with: Data("--".utf8)) {
        guard body[cursor...].starts(with: Data("\r\n".utf8)) else { return nil }
        let partStart = cursor + 2
        guard let next = body.range(of: Data("\r\n".utf8) + delimiter, in: partStart..<body.endIndex),
              let split = body.range(of: crlfcrlf, in: partStart..<next.lowerBound)
        else { return nil }
        let head = String(decoding: body[partStart..<split.lowerBound], as: UTF8.self)
        if let part = formPart(head: head, data: Data(body[split.upperBound..<next.lowerBound])) {
            parts.append(part)
        }
        cursor = next.upperBound
    }
    return parts
}

func formPart(head: String, data: Data) -> FormPart? {
    guard let disposition = head.components(separatedBy: "\r\n")
        .first(where: { $0.lowercased().hasPrefix("content-disposition:") }) else { return nil }
    var name: String?, filename: String?
    for field in disposition.components(separatedBy: ";").dropFirst() {
        let pair = field.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        guard pair.count == 2 else { continue }
        let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch pair[0].lowercased() {
        case "name": name = value
        case "filename": filename = value
        default: break
        }
    }
    guard let name else { return nil }
    return FormPart(name: name, filename: filename, data: data)
}

// The file extension T3 accepts for these image bytes, or nil.
public func imageExtension(_ data: Data) -> String? {
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if data.starts(with: Data("GIF8".utf8)) { return "gif" }
    if data.starts(with: Data("RIFF".utf8)), data.count >= 12,
       data[data.startIndex + 8..<data.startIndex + 12] == Data("WEBP".utf8) { return "webp" }
    return nil
}

// Compares without leaking where the first difference is.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = UInt8(x.count == y.count ? 0 : 1)
    for i in 0..<min(x.count, y.count) { diff |= x[i] ^ y[i] }
    return diff == 0
}

// What the routes need from the app, injected so tests can stand in.
public struct ReceiverContext {
    public let token: String
    public let defaultRoot: String
    public let projects: () -> [Project]
    // Writes the image and returns its file.
    public let saveImage: (Data, String) throws -> URL
    // Runs the dispatch command: prompt, image, project folder.
    public let dispatch: (String, URL, String) -> (ok: Bool, output: String)

    public init(token: String, defaultRoot: String, projects: @escaping () -> [Project],
                saveImage: @escaping (Data, String) throws -> URL,
                dispatch: @escaping (String, URL, String) -> (ok: Bool, output: String)) {
        self.token = token
        self.defaultRoot = defaultRoot
        self.projects = projects
        self.saveImage = saveImage
        self.dispatch = dispatch
    }
}

public func handle(_ request: HTTPRequest, _ ctx: ReceiverContext) -> HTTPResponse {
    let routes = ["/projects": "GET", "/shot": "POST"]
    guard let method = routes[request.path] else { return HTTPResponse(status: 404, text: "not found") }
    guard constantTimeEqual(request.headers["authorization"] ?? "", "Bearer \(ctx.token)") else {
        return HTTPResponse(status: 401, text: "wrong or missing token")
    }
    guard request.method == method else { return HTTPResponse(status: 405, text: "use \(method)") }
    let entries = pickerEntries(projects: ctx.projects(), defaultRoot: ctx.defaultRoot)
    if request.path == "/projects" {
        // A JSON array of names: Shortcuts' Choose from List takes it as is.
        return HTTPResponse(status: 200, json: try! JSONEncoder().encode(entries.map(\.name)))
    }
    guard let shot = parseShot(body: request.body, contentType: request.headers["content-type"] ?? "") else {
        return HTTPResponse(status: 400, text: "send JSON (prompt, image as base64, project) or a multipart form")
    }
    guard let image = shot.image, !image.isEmpty else { return HTTPResponse(status: 400, text: "no image") }
    guard let ext = imageExtension(image) else {
        return HTTPResponse(status: 415, text: "T3 takes PNG, JPEG, GIF or WebP images")
    }
    let wanted = shot.project.trimmingCharacters(in: .whitespacesAndNewlines)
    var entry = entries[0], text = shot.prompt
    if !wanted.isEmpty {
        guard let named = entries.first(where: { $0.name == wanted }) else {
            return HTTPResponse(status: 400, text: "unknown project: \(wanted)")
        }
        entry = named
    } else if let picked = projectPrefix(shot.prompt, entries: entries) {
        (entry, text) = picked
    }
    guard let prompt = sendablePrompt(text) else { return HTTPResponse(status: 400, text: "empty prompt") }
    let file: URL
    do { file = try ctx.saveImage(image, ext) } catch {
        return HTTPResponse(status: 502, text: "could not save the image: \(error.localizedDescription)")
    }
    let (ok, output) = ctx.dispatch(prompt, file, entry.root)
    return ok ? HTTPResponse(status: 200, text: "Started a T3 thread in \(entry.name).")
              : HTTPResponse(status: 502, text: "dispatch failed: \(output)")
}

// What a /shot body carries.
public struct Shot: Equatable {
    public let prompt: String
    public let project: String
    public let image: Data?
}

// A multipart form (prompt, project, image file), or JSON with the image as
// base64, which is what the iPhone shortcut sends. Nil when it is neither.
public func parseShot(body: Data, contentType: String) -> Shot? {
    if contentType.lowercased().hasPrefix("application/json") {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let image = (object["image"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        return Shot(prompt: object["prompt"] as? String ?? "", project: object["project"] as? String ?? "",
                    image: image)
    }
    guard let parts = parseMultipart(body: body, contentType: contentType) else { return nil }
    let field = { (name: String) in
        parts.first { $0.name == name }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
    }
    return Shot(prompt: field("prompt"), project: field("project"), image: parts.first { $0.name == "image" }?.data)
}

// "@name rest of prompt" sends the thread to the project called name (any
// case; "ovou-platform" also matches "ovou-platform · ovou"). The first match
// in picker order wins, so the most recently used one. Nil when the prompt has
// no such prefix; an @word that names no project stays part of the prompt.
public func projectPrefix(_ prompt: String, entries: [PickerEntry]) -> (PickerEntry, String)? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("@") else { return nil }
    let word = trimmed.dropFirst().prefix { !$0.isWhitespace }.lowercased()
    let short = { (name: String) in name.components(separatedBy: " · ")[0].lowercased() }
    guard !word.isEmpty, let entry = entries.first(where: { $0.name.lowercased() == word || short($0.name) == word })
    else { return nil }
    return (entry, String(trimmed.dropFirst(word.count + 1)))
}

// Writes phone images to `dir` as PHONE-<time>.<ext>; the name never matches
// Shottr's SCR- captures, so the capture watcher ignores them.
public func imageSaver(dir: URL, now: @escaping () -> Date = Date.init) -> (Data, String) throws -> URL {
    { data, ext in
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let file = dir.appendingPathComponent("PHONE-\(f.string(from: now()))-\(UUID().uuidString.prefix(6)).\(ext)")
        try data.write(to: file)
        return file
    }
}
