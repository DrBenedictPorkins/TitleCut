import Foundation
import MCP
import Network

/// A minimal HTTP/1.1 server on 127.0.0.1 for MCP's Streamable HTTP
/// transport (§10.1, D4 revised 2026-10-14). One request per connection;
/// every response closes the connection, so a streamed (SSE) body simply
/// ends when the stream does.
///
/// Requests are handed to `handle` as the SDK's `HTTPRequest`; its
/// `HTTPResponse` is written back.
final class MCPHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.byteclub.titlecut.mcp.http")
    private let handle: Handler

    /// The bound port.
    let port: UInt16

    /// Binds 127.0.0.1:`port`. Throws if the port is taken.
    init(port: UInt16, handle: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                    port: NWEndpoint.Port(rawValue: port)!)
        // Closing connections of a previous run (TIME_WAIT) must not block the port.
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.port = port
        self.handle = handle
    }

    /// Starts listening. `ready` reports whether the bind succeeded.
    func start(ready: @escaping @Sendable (Bool) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready(true)
            case .failed, .cancelled: ready(false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    /// Whether 127.0.0.1:`port` can be bound now.
    static func isFree(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        // As the listener does: only a live listener makes the port taken.
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads until the headers and `Content-Length` body are in.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                Task { await self.respond(to: request, on: connection) }
            } else if complete || error != nil || buffer.count > 16 << 20 {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    /// The request in `data`, or `nil` while it is incomplete.
    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = headers.first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value) } ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = length > 0 ? Data(data[bodyStart..<bodyStart + length]) : nil
        return HTTPRequest(method: String(start[0]), headers: headers, body: body,
                           path: String(start[1]))
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let response: HTTPResponse
        if let path = request.path, path.split(separator: "?").first != "/mcp" {
            response = .error(statusCode: 404, .invalidRequest("Not Found: use /mcp"))
        } else {
            response = await handle(request)
        }
        var head = "HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\n"
        var headers = response.headers
        headers["Connection"] = "close"
        let body = response.bodyData
        if let body { headers["Content-Length"] = String(body.count) }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var first = Data(head.utf8)
        if let body { first.append(body) }
        await send(first, on: connection)
        if case .stream(let stream, _) = response {
            do {
                for try await chunk in stream { await send(chunk, on: connection) }
            } catch {}
        }
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in done.resume() })
        }
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        default: "Error"
        }
    }
}
