import Foundation
import Network

// Serves `handler` on 127.0.0.1:<port>, one request per connection. Only
// loopback: the phone reaches it through `tailscale serve`, never directly.
public final class ReceiverServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "shot-prompt.receiver")
    let handler: (HTTPRequest) -> HTTPResponse
    let maxBody: Int

    public init(port: UInt16, maxBody: Int = maxReceiverBody,
                handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        self.handler = handler
        self.maxBody = maxBody
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
                DispatchQueue.global().async { self.reply(connection, self.handler(request)) }
            case .respond(let response): reply(connection, response)
            case .readMore(let buffer): read(connection, buffer)
            }
        }
    }

    func reply(_ connection: NWConnection, _ response: HTTPResponse) {
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
    case .bad: return .respond(HTTPResponse(status: 400, text: "bad request"))
    case .tooLarge: return .respond(HTTPResponse(status: 413, text: "image too large"))
    case .incomplete:
        // A reply the client cannot read just fails.
        return closed ? .respond(HTTPResponse(status: 400, text: "incomplete request")) : .readMore(buffer)
    }
}
