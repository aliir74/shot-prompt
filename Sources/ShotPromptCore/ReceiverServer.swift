import Foundation
import Network

// Serves `handler` on 127.0.0.1:<port>, one request per connection. Only
// loopback: the phone reaches it through `tailscale serve`, never directly.
public final class ReceiverServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "shot-prompt.receiver")
    let handler: (HTTPRequest) -> HTTPResponse
    let maxBody: Int
    // Gets every reply with its request (nil when the request never parsed), for the log.
    let onReply: ((HTTPRequest?, HTTPResponse) -> Void)?

    public init(port: UInt16, maxBody: Int = maxReceiverBody,
                onReply: ((HTTPRequest?, HTTPResponse) -> Void)? = nil,
                handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        self.handler = handler
        self.maxBody = maxBody
        self.onReply = onReply
    }

    // `onState` gets nil once listening, or the error text if it fails.
    public func start(onState: @escaping (String?) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState(nil)
            case .failed(let error): onState(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            switch readStep(buffer: buffer, data: data, closed: isComplete || error != nil, maxBody: maxBody) {
            case .handle(let request):
                // Dispatch can take seconds; keep the listener queue free.
                DispatchQueue.global().async { self.reply(connection, self.handler(request), to: request) }
            case .respond(let response): reply(connection, response, to: nil)
            case .readMore(let buffer): read(connection, buffer)
            }
        }
    }

    func reply(_ connection: NWConnection, _ response: HTTPResponse, to request: HTTPRequest?) {
        onReply?(request, response)
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}

public enum ReadStep: Equatable {
    case handle(HTTPRequest)
    case respond(HTTPResponse)
    case readMore(Data)
}

// What to do after a read: `data` is what just arrived (nil at end of stream),
// `closed` says the client stopped sending or the connection failed.
public func readStep(buffer: Data, data: Data?, closed: Bool, maxBody: Int) -> ReadStep {
    let buffer = buffer + (data ?? Data())
    switch parseRequest(buffer, maxBody: maxBody) {
    case .done(let request): return .handle(request)
    case .bad: return .respond(HTTPResponse(status: 400, message: "bad request"))
    case .tooLarge: return .respond(HTTPResponse(status: 413, message: "image too large"))
    case .incomplete:
        // A reply the client cannot read just fails.
        return closed ? .respond(HTTPResponse(status: 400, message: "incomplete request")) : .readMore(buffer)
    }
}

// One log line per reply: "POST /shot -> 502 dispatch failed: …". The message
// comes from a JSON reply's "message" (plus its "appLink") or a text body, on one line, capped.
// Never the request body or headers: they hold the image and the token.
public func replyLogLine(_ request: HTTPRequest?, _ response: HTTPResponse, cap: Int = 600) -> String {
    let route = request.map { "\($0.method) \($0.path)" } ?? "unparsed request"
    let json = response.contentType == "application/json"
        ? (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] : nil
    var message = json == nil && response.contentType != "application/json"
        ? String(decoding: response.body, as: UTF8.self) : json?["message"] as? String ?? ""
    // The thread a shot opened, so "the link opened the wrong thread" can be checked.
    if let link = json?["appLink"] as? String { message += " " + link }
    var line = "\(route) -> \(response.status)"
    let flat = message.split(whereSeparator: \.isNewline).joined(separator: " | ")
    if !flat.isEmpty { line += " " + (flat.count > cap ? String(flat.prefix(cap)) + "…" : flat) }
    return line
}
