import XCTest
@testable import ShotPromptCore

let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

// A multipart body the way Shortcuts' Form request body sends it.
func form(_ fields: [(String, String?, Data)], boundary: String = "Bnd") -> Data {
    var body = Data()
    for (name, filename, data) in fields {
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"".utf8)
        if let filename { body += Data("; filename=\"\(filename)\"\r\nContent-Type: image/png".utf8) }
        body += Data("\r\n\r\n".utf8) + data + Data("\r\n".utf8)
    }
    return body + Data("--\(boundary)--\r\n".utf8)
}

final class ReceiverParseTests: XCTestCase {
    func testSettings() {
        XCTAssertNil(receiverSettings(port: 0, token: "t"))
        XCTAssertNil(receiverSettings(port: 70000, token: "t"))
        XCTAssertNil(receiverSettings(port: 8790, token: nil))
        XCTAssertNil(receiverSettings(port: 8790, token: ""))
        XCTAssertEqual(receiverSettings(port: 8790, token: "t")?.port, 8790)
        XCTAssertEqual(receiverSettings(port: 8790, token: "t")?.token, "t")
    }

    func testParseRequest() {
        let raw = Data("POST /shot?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\nX-Up:  v \r\n\r\nabcEXTRA".utf8)
        XCTAssertEqual(parseRequest(raw), .done(HTTPRequest(
            method: "POST", path: "/shot",
            headers: ["host": "a", "content-length": "3", "x-up": "v"], body: Data("abc".utf8))))
        XCTAssertEqual(parseRequest(Data("GET /projects HTTP/1.1\r\n\r\n".utf8)),
                       .done(HTTPRequest(method: "GET", path: "/projects")))
    }

    func testParseIncompleteBadAndTooLarge() {
        XCTAssertEqual(parseRequest(Data("GET / HTTP/1.1\r\nHost".utf8)), .incomplete)
        XCTAssertEqual(parseRequest(Data("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\nabc".utf8)), .incomplete)
        XCTAssertEqual(parseRequest(Data(repeating: 65, count: 70_000)), .bad)
        XCTAssertEqual(parseRequest(Data([0xFF, 0xFE]) + crlfcrlf), .bad)
        XCTAssertEqual(parseRequest(Data("GET /\r\n\r\n".utf8)), .bad)
        XCTAssertEqual(parseRequest(Data("GET / HTTP/1.1\r\nnocolon\r\n\r\n".utf8)), .bad)
        XCTAssertEqual(parseRequest(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .bad)
        XCTAssertEqual(parseRequest(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)), .bad)
        XCTAssertEqual(parseRequest(Data("POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8), maxBody: 10),
                       .tooLarge)
    }

    func testSerialized() {
        let text = String(decoding: HTTPResponse(status: 401, text: "no").serialized(), as: UTF8.self)
        XCTAssertEqual(text, "HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain; charset=utf-8\r\n"
                       + "Content-Length: 2\r\nConnection: close\r\n\r\nno")
        let odd = String(decoding: HTTPResponse(status: 500, json: Data("[]".utf8)).serialized(), as: UTF8.self)
        XCTAssertTrue(odd.hasPrefix("HTTP/1.1 500 Error\r\nContent-Type: application/json\r\n"))
    }

    func testMultipart() {
        let body = form([("prompt", nil, Data("fix this".utf8)), ("image", "s.png", png)])
        XCTAssertEqual(parseMultipart(body: body, contentType: "multipart/form-data; boundary=\"Bnd\""), [
            FormPart(name: "prompt", filename: nil, data: Data("fix this".utf8)),
            FormPart(name: "image", filename: "s.png", data: png),
        ])
        // A part with no name, an empty value, and a field with no '=' are handled.
        let odd = Data("--B\r\nContent-Disposition: form-data; x; name=\"a\"; size=1\r\n\r\n\r\n".utf8)
            + Data("--B\r\nContent-Type: text/plain\r\n\r\nv\r\n--B--".utf8)
        XCTAssertEqual(parseMultipart(body: odd, contentType: "multipart/form-data; boundary=B"),
                       [FormPart(name: "a", filename: nil, data: Data())])
        let nameless = Data("--B\r\nContent-Disposition: form-data\r\n\r\nv\r\n--B--".utf8)
        XCTAssertEqual(parseMultipart(body: nameless, contentType: "multipart/form-data; boundary=B"), [])
    }

    func testMultipartRejects() {
        let ok = form([("a", nil, Data("1".utf8))])
        XCTAssertNil(parseMultipart(body: ok, contentType: "application/json"))
        XCTAssertNil(parseMultipart(body: ok, contentType: "multipart/form-data"))
        XCTAssertNil(parseMultipart(body: ok, contentType: "multipart/form-data; boundary=\"\""))
        XCTAssertNil(parseMultipart(body: Data("nothing".utf8), contentType: "multipart/form-data; boundary=Bnd"))
        XCTAssertNil(parseMultipart(body: Data("--BndXX".utf8), contentType: "multipart/form-data; boundary=Bnd"))
        XCTAssertNil(parseMultipart(body: Data("--Bnd\r\nunterminated".utf8),
                                    contentType: "multipart/form-data; boundary=Bnd"))
        XCTAssertNil(parseMultipart(body: Data("--Bnd\r\nno blank line\r\n--Bnd--".utf8),
                                    contentType: "multipart/form-data; boundary=Bnd"))
    }

    func testImageExtension() {
        XCTAssertEqual(imageExtension(png), "png")
        XCTAssertEqual(imageExtension(Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(imageExtension(Data("GIF89a".utf8)), "gif")
        XCTAssertEqual(imageExtension(Data("RIFF0000WEBPVP8".utf8)), "webp")
        XCTAssertNil(imageExtension(Data("RIFF0000WAVE".utf8)))
        XCTAssertNil(imageExtension(Data("RIFF".utf8)))
        XCTAssertNil(imageExtension(Data("....ftypheic".utf8)))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(constantTimeEqual("abc", "abc"))
        XCTAssertFalse(constantTimeEqual("abc", "abd"))
        XCTAssertFalse(constantTimeEqual("abc", "ab"))
    }

    func testImageSaver() throws {
        let dir = try makeTempDir(self).appendingPathComponent("phone")
        let save = imageSaver(dir: dir, now: { Date(timeIntervalSince1970: 1_780_000_000) })
        let file = try save(png, "png")
        XCTAssertEqual(try Data(contentsOf: file), png)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("PHONE-2026"))
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertTrue(try imageSaver(dir: dir)(png, "png").lastPathComponent.hasPrefix("PHONE-"))
        // A file where the folder should be makes saving fail.
        let blocked = try makeTempDir(self).appendingPathComponent("f")
        try Data().write(to: blocked)
        XCTAssertThrowsError(try imageSaver(dir: blocked)(png, "png"))
    }
}

final class ReceiverHandleTests: XCTestCase {
    var dispatched: [(String, URL, String)] = []
    var dispatchResult = (ok: true, output: "")
    var saveError: Error?

    let projects = [Project(title: "Vault26", root: "/v"), Project(title: "shot-prompt", root: "/s")]

    func context() -> ReceiverContext {
        ReceiverContext(
            token: "secret", defaultRoot: "/s", projects: { self.projects },
            saveImage: { _, ext in
                if let e = self.saveError { throw e }
                return URL(fileURLWithPath: "/tmp/img.\(ext)")
            },
            dispatch: { p, i, c in self.dispatched.append((p, i, c)); return self.dispatchResult })
    }

    func request(_ method: String = "POST", _ path: String = "/shot", token: String? = "secret",
                 body: Data = Data(), contentType: String = "multipart/form-data; boundary=Bnd") -> HTTPRequest {
        var headers = ["content-type": contentType]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    func text(_ r: HTTPResponse) -> String { String(decoding: r.body, as: UTF8.self) }

    func testRoutingAndAuth() {
        XCTAssertEqual(handle(request("GET", "/nope"), context()).status, 404)
        XCTAssertEqual(handle(request("GET", "/projects", token: nil), context()).status, 401)
        XCTAssertEqual(handle(request("GET", "/projects", token: "wrong"), context()).status, 401)
        XCTAssertEqual(handle(request("GET", "/shot"), context()).status, 405)
    }

    func testProjects() throws {
        let r = handle(request("GET", "/projects"), context())
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.contentType, "application/json")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: r.body), ["shot-prompt", "Vault26"])
    }

    func testShotDefaultProject() {
        let r = handle(request(body: form([("prompt", nil, Data(" why? ".utf8)), ("image", "a.png", png)])), context())
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(text(r), "Started a T3 thread in shot-prompt.")
        XCTAssertEqual(dispatched.map(\.0), ["why?"])
        XCTAssertEqual(dispatched.map(\.1.path), ["/tmp/img.png"])
        XCTAssertEqual(dispatched.map(\.2), ["/s"])
    }

    func testShotPickedProject() {
        let body = form([("prompt", nil, Data("p".utf8)), ("project", nil, Data("Vault26\n".utf8)),
                         ("image", "a.png", png)])
        XCTAssertEqual(handle(request(body: body), context()).status, 200)
        XCTAssertEqual(dispatched.map(\.2), ["/v"])
    }

    func testShotRejects() {
        let c = context()
        XCTAssertEqual(handle(HTTPRequest(method: "POST", path: "/shot", headers: ["authorization": "Bearer secret"]),
                              c).status, 400)
        XCTAssertEqual(text(handle(request(contentType: "text/plain"), c)),
                       "send JSON (prompt, image as base64, project) or a multipart form")
        XCTAssertEqual(text(handle(request(body: form([("image", "a.png", png)])), c)), "empty prompt")
        XCTAssertEqual(text(handle(request(body: form([("prompt", nil, Data("p".utf8))])), c)), "no image")
        let heic = form([("prompt", nil, Data("p".utf8)), ("image", "a.heic", Data("xxxxftypheic".utf8))])
        XCTAssertEqual(handle(request(body: heic), c).status, 415)
        let unknown = form([("prompt", nil, Data("p".utf8)), ("project", nil, Data("Gone".utf8)),
                            ("image", "a.png", png)])
        XCTAssertEqual(text(handle(request(body: unknown), c)), "unknown project: Gone")
        XCTAssertTrue(dispatched.isEmpty)
    }

    func testShotFailures() {
        let body = form([("prompt", nil, Data("p".utf8)), ("image", "a.png", png)])
        saveError = CocoaError(.fileWriteNoPermission)
        XCTAssertEqual(handle(request(body: body), context()).status, 502)
        saveError = nil
        dispatchResult = (false, "T3 is not running")
        let r = handle(request(body: body), context())
        XCTAssertEqual(r.status, 502)
        XCTAssertEqual(text(r), "dispatch failed: T3 is not running")
    }
}

final class ReceiverShotTests: XCTestCase {
    let entries = pickerEntries(projects: [Project(title: "ovou-platform", root: "/a/ovou/ovou-platform"),
                                           Project(title: "ovou-platform", root: "/a/Coding/ovou-platform"),
                                           Project(title: "Vault26", root: "/v")], defaultRoot: "/v")

    func testParseShotJSON() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "prompt": "چرا؟", "project": "Vault26",
            // Shortcuts' Base64 Encode can wrap lines; those are ignored.
            "image": png.base64EncodedString(options: .lineLength64Characters) + "\r\n"])
        XCTAssertEqual(parseShot(body: body, contentType: "application/json; charset=utf-8"),
                       Shot(prompt: "چرا؟", project: "Vault26", image: png))
        XCTAssertEqual(parseShot(body: Data("{}".utf8), contentType: "application/json"),
                       Shot(prompt: "", project: "", image: nil))
        XCTAssertNil(parseShot(body: Data("[1]".utf8), contentType: "application/json"))
        XCTAssertNil(parseShot(body: Data("nope".utf8), contentType: "application/json"))
    }

    func testParseShotMultipart() {
        let body = form([("prompt", nil, Data("p".utf8)), ("image", "a.png", png)])
        XCTAssertEqual(parseShot(body: body, contentType: "multipart/form-data; boundary=Bnd"),
                       Shot(prompt: "p", project: "", image: png))
        XCTAssertNil(parseShot(body: body, contentType: "text/plain"))
    }

    func testProjectPrefix() {
        XCTAssertNil(projectPrefix("no prefix", entries: entries))
        XCTAssertNil(projectPrefix("@ alone", entries: entries))
        XCTAssertNil(projectPrefix("@someone said this", entries: entries))
        let vault = projectPrefix("  @vault26 why is this red?", entries: entries)
        XCTAssertEqual(vault?.0.root, "/v")
        XCTAssertEqual(vault?.1, " why is this red?")
        // A shared title matches its first (most recent) project.
        XCTAssertEqual(projectPrefix("@OVOU-platform fix", entries: entries)?.0.root, "/a/ovou/ovou-platform")
    }

    func testHandleJSONWithPrefix() throws {
        var sent: [(String, String)] = []
        let ctx = ReceiverContext(
            token: "t", defaultRoot: "/v",
            projects: { [Project(title: "shot-prompt", root: "/s"), Project(title: "Vault26", root: "/v")] },
            saveImage: { _, ext in URL(fileURLWithPath: "/tmp/x.\(ext)") },
            dispatch: { p, _, c in sent.append((p, c)); return (true, "") })
        func post(_ object: [String: String]) throws -> HTTPResponse {
            handle(HTTPRequest(method: "POST", path: "/shot",
                               headers: ["authorization": "Bearer t", "content-type": "application/json"],
                               body: try JSONSerialization.data(withJSONObject: object)), ctx)
        }
        let image = png.base64EncodedString()
        XCTAssertEqual(try post(["prompt": "@shot-prompt  fix the icon", "image": image]).status, 200)
        XCTAssertEqual(try post(["prompt": "@shot-prompt", "image": image]).status, 400)
        XCTAssertEqual(try post(["prompt": "p", "image": ""]).status, 400)
        XCTAssertEqual(try post(["prompt": "@shot-prompt p", "project": "Vault26", "image": image]).status, 200)
        XCTAssertEqual(sent.map(\.0), ["fix the icon", "@shot-prompt p"])
        XCTAssertEqual(sent.map(\.1), ["/s", "/v"])
    }
}
