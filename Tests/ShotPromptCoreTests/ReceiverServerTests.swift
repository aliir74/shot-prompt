import Network
import XCTest
@testable import ShotPromptCore

final class ReceiverServerTests: XCTestCase {
    // A port the OS just handed out, so parallel CI jobs never collide on it.
    func freePort() -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(fd, $0, len)
                _ = Darwin.getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    // Starts a server and waits until it listens.
    func startServer(port: UInt16, maxBody: Int = maxReceiverBody,
                     onReply: ((HTTPRequest?, HTTPResponse) -> Void)? = nil,
                     handler: @escaping (HTTPRequest) -> HTTPResponse) throws -> ReceiverServer {
        let server = try ReceiverServer(port: port, maxBody: maxBody, onReply: onReply, handler: handler)
        let ready = expectation(description: "ready")
        server.start { error in XCTAssertNil(error); ready.fulfill() }
        wait(for: [ready], timeout: 5)
        addTeardownBlock { server.stop() }
        return server
    }

    // Sends raw bytes (optionally in two writes, or half-closing early) and returns the reply.
    func exchange(port: UInt16, _ chunks: [Data], closeAfterSend: Bool = false) -> String {
        let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = expectation(description: "reply")
        var reply = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                reply += data ?? Data()
                if complete || error != nil { done.fulfill() } else { receive() }
            }
        }
        conn.start(queue: .global())
        // Later chunks go 0.3 s apart, so the server reads them separately.
        var parts: [(Data, NWConnection.ContentContext)] = chunks.map { ($0, .defaultMessage) }
        if closeAfterSend { parts.append((Data(), .finalMessage)) }
        for (i, part) in parts.enumerated() {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3 * Double(i)) {
                conn.send(content: part.0.isEmpty ? nil : part.0, contentContext: part.1, isComplete: true,
                          completion: .contentProcessed { _ in })
            }
        }
        receive()
        wait(for: [done], timeout: 5)
        conn.cancel()
        return String(decoding: reply, as: UTF8.self)
    }

    func testServesRequestsSplitAcrossReads() throws {
        let port = freePort()
        _ = try startServer(port: port) { req in HTTPResponse(status: 200, text: "got \(req.method) \(req.body.count)") }
        let reply = exchange(port: port, [Data("POST /shot HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8),
                                          Data("cd".utf8)])
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
        XCTAssertTrue(reply.hasSuffix("got POST 4"), reply)
    }

    func testBadAndTooLarge() throws {
        let port = freePort()
        _ = try startServer(port: port, maxBody: 10) { _ in HTTPResponse(status: 200, text: "") }
        XCTAssertTrue(exchange(port: port, [Data("nonsense\r\n\r\n".utf8)]).hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(exchange(port: port, [Data("POST / HTTP/1.1\r\nContent-Length: 99\r\n\r\n".utf8)])
            .hasPrefix("HTTP/1.1 413"))
    }

    func testClientHangsUpMidRequest() throws {
        let port = freePort()
        _ = try startServer(port: port) { _ in HTTPResponse(status: 200, text: "") }
        XCTAssertTrue(exchange(port: port, [Data("GET / HTTP/1.1\r\n".utf8)], closeAfterSend: true)
            .contains("incomplete request"))
    }

    func testReadStep() {
        XCTAssertEqual(readStep(buffer: Data("GET / HT".utf8), data: nil, closed: false, maxBody: 10),
                       .readMore(Data("GET / HT".utf8)))
        XCTAssertEqual(readStep(buffer: Data(), data: Data("GET / HT".utf8), closed: true, maxBody: 10),
                       .respond(HTTPResponse(status: 400, message: "incomplete request")))
        XCTAssertEqual(readStep(buffer: Data("GET / HTTP/1.1\r\n".utf8), data: Data("\r\n".utf8), closed: false,
                                maxBody: 10), .handle(HTTPRequest(method: "GET", path: "/")))
    }

    func testPortInUseFails() throws {
        let port = freePort()
        _ = try startServer(port: port) { _ in HTTPResponse(status: 200, text: "") }
        let second = try ReceiverServer(port: port) { _ in HTTPResponse(status: 200, text: "") }
        let failed = expectation(description: "failed")
        second.start { error in XCTAssertNotNil(error); failed.fulfill() }
        wait(for: [failed], timeout: 5)
        second.stop()
    }

    func testReportsEveryReplyWithItsRequest() throws {
        let port = freePort()
        var lines: [String] = []
        let lock = NSLock()
        _ = try startServer(port: port, maxBody: 10, onReply: { req, res in
            lock.lock(); lines.append(replyLogLine(req, res)); lock.unlock()
        }) { _ in HTTPResponse(status: 502, message: "dispatch failed: boom") }
        _ = exchange(port: port, [Data("POST /shot HTTP/1.1\r\nContent-Length: 2\r\n\r\nab".utf8)])
        _ = exchange(port: port, [Data("POST / HTTP/1.1\r\nContent-Length: 99\r\n\r\n".utf8)])
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(lines, ["POST /shot -> 502 dispatch failed: boom", "unparsed request -> 413 image too large"])
    }

    func testReplyLogLine() {
        let req = HTTPRequest(method: "GET", path: "/projects")
        XCTAssertEqual(replyLogLine(req, HTTPResponse(status: 200, json: Data("[\"a\"]".utf8))), "GET /projects -> 200")
        XCTAssertEqual(replyLogLine(req, HTTPResponse(status: 200, json: Data("{}".utf8))), "GET /projects -> 200")
        XCTAssertEqual(replyLogLine(nil, HTTPResponse(status: 400, text: "a\nb")), "unparsed request -> 400 a | b")
        XCTAssertEqual(replyLogLine(req, HTTPResponse(status: 502, message: "abcdef"), cap: 3), "GET /projects -> 502 abc…")
    }
}
