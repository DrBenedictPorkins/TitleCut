import Foundation
import MCP
import Observation
import Synchronization

/// TitleCut's MCP server, as the top bar's MCP button shows it: off, or
/// listening on a localhost port with the Claude Code sessions connected.
///
/// Off the first time; afterwards it comes back as it was at quit. The port
/// is remembered so the Claude Code registration keeps working; if it is
/// taken, the next free one is used and the panel says so.
@MainActor
@Observable
final class MCPService {
    static let shared = MCPService()

    enum State: Equatable {
        case off
        case on(port: UInt16)
        case failed(String)
    }

    private(set) var state = State.off
    /// Whether requests must carry the key. Saved; off by default for now
    /// (PLAN: on before release). While off the keychain is never read.
    var keyRequired = UserDefaults.standard.bool(forKey: MCPService.keyRequiredKey) {
        didSet {
            UserDefaults.standard.set(keyRequired, forKey: Self.keyRequiredKey)
            if keyRequired, key == nil { key = MCPKey.current }
            Self.requireKey.withLock { $0 = keyRequired }
        }
    }
    /// The access key; read from the keychain only once it is required.
    private(set) var key: String?

    nonisolated private static let keyRequiredKey = "mcpKeyRequired"
    /// `keyRequired`, readable from the request handlers off the main actor.
    nonisolated static let requireKey = Mutex(UserDefaults.standard.bool(forKey: keyRequiredKey))
    /// Set when the remembered port was taken and another was used.
    private(set) var portNote: String?

    @ObservationIgnored private var server: MCPHTTPServer?
    @ObservationIgnored private let sessions = MCPSessions()

    private static let enabledKey = "mcpEnabled"
    private static let portKey = "mcpPort"
    static let defaultPort: UInt16 = 7340

    var isOn: Bool { if case .on = state { true } else { false } }

    var port: UInt16? { if case .on(let port) = state { port } else { nil } }

    var url: String? { port.map { "http://127.0.0.1:\($0)/mcp" } }

    /// The command that registers TitleCut in Claude Code, with the key
    /// when one is required.
    var setupCommand: String? {
        guard let url else { return nil }
        let command = "claude mcp add --transport http titlecut \(url)"
        guard keyRequired, let key else { return command }
        return command + " --header \"Authorization: Bearer \(key)\""
    }

    /// Makes a new key; clients registered with the old one are refused.
    func renewKey() {
        key = MCPKey.renew()
    }

    private init() {
        if keyRequired { key = MCPKey.current }
    }

    /// Turns the server back on at launch if it was on at quit.
    func restore() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    func start() {
        guard server == nil else { return }
        let remembered = UInt16(UserDefaults.standard.integer(forKey: Self.portKey))
        let preferred = remembered > 0 ? remembered : Self.defaultPort
        guard let port = (0..<100).lazy.map({ preferred &+ UInt16($0) })
            .first(where: MCPHTTPServer.isFree) else {
            state = .failed("No free port from \(preferred) to \(preferred + 99).")
            return
        }
        portNote = port == preferred || remembered == 0 ? nil
            : "Port \(preferred) was in use, so TitleCut is on \(port). Update the Claude Code "
              + "registration with the command below."
        do {
            let sessions = sessions
            let server = try MCPHTTPServer(port: port) { request in
                await sessions.handle(request)
            }
            self.server = server
            server.start { ready in
                Task { @MainActor in MCPService.shared.listening(ready, port: port) }
            }
        } catch {
            state = .failed("Port \(port) could not be opened: \(error.localizedDescription)")
        }
    }

    private func listening(_ ready: Bool, port: UInt16) {
        guard server?.port == port else { return }
        if ready {
            state = .on(port: port)
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            // A stand-in port is not remembered: next time the usual one is tried first.
            if portNote == nil { UserDefaults.standard.set(Int(port), forKey: Self.portKey) }
        } else if isOn || state == .off {
            server = nil
            state = .failed("Port \(port) stopped listening.")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        state = .off
        portNote = nil
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        Task { await sessions.removeAll() }
    }

}

/// One MCP `Server` and transport per Claude Code session, keyed by the
/// `MCP-Session-Id` the transport assigns at initialize.
actor MCPSessions {
    private struct Entry {
        let server: Server
        let transport: StatefulHTTPServerTransport
    }

    private var entries: [String: Entry] = [:]

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard !MCPService.requireKey.withLock({ $0 })
                || MCPKey.accepts(request.header(HTTPHeaderName.authorization)) else {
            return .error(statusCode: 401,
                          .invalidRequest("Unauthorized: send the TitleCut MCP key as "
                                          + "Authorization: Bearer <key>. The key is in "
                                          + "TitleCut's MCP panel."),
                          extraHeaders: ["WWW-Authenticate": "Bearer"])
        }
        if let id = request.header(HTTPHeaderName.sessionID) {
            guard let entry = entries[id] else {
                // Unknown after a restart: the client starts a new session.
                return .error(statusCode: 404, .invalidRequest("Session not found"))
            }
            let response = await entry.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" { entries[id] = nil }
            return response
        }
        guard request.method.uppercased() == "POST", let body = request.body,
              Self.isInitialize(body) else {
            return .error(statusCode: 400,
                          .invalidRequest("Bad Request: send initialize first, without a session"))
        }
        let transport = StatefulHTTPServerTransport()
        let gate = MCPGate()
        // The instructions also go out in the standard initialize handshake.
        let server = Server(name: "titlecut",
                            version: Bundle.main.object(
                                forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                                ?? "0.1.0",
                            instructions: ToolCatalog.instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.tools) }
        await server.withMethodHandler(CallTool.self) { params in
            await gate.call(params.name, arguments: params.arguments ?? [:])
        }
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(statusCode: 500, .internalError("The MCP server could not start."))
        }
        let response = await transport.handleRequest(request)
        if let id = response.headers.first(where: {
            $0.key.caseInsensitiveCompare(HTTPHeaderName.sessionID) == .orderedSame
        })?.value {
            entries[id] = Entry(server: server, transport: transport)
        }
        return response
    }

    func removeAll() async {
        for entry in entries.values { await entry.server.stop() }
        entries = [:]
    }

    private static func isInitialize(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "initialize"
    }
}

/// The get_instructions gate for one session (the standing MCP rule): every
/// other tool is refused until get_instructions has been called.
final class MCPGate: @unchecked Sendable {
    private let lock = NSLock()
    private var read = false

    static let message = "Call get_instructions() first to initialize this MCP server before "
        + "using any other tools."

    func call(_ tool: String, arguments: [String: Value]) async -> CallTool.Result {
        if tool == "get_instructions" {
            lock.withLock { read = true }
            return .init(content: [.text(ToolCatalog.manual)], isError: false)
        }
        guard lock.withLock({ read }) else {
            return .init(content: [.text(Self.message)], isError: true)
        }
        guard ToolCatalog.names.contains(tool) else {
            return .init(content: [.text("Unknown tool \(tool). Call get_instructions() for "
                                         + "the list.")], isError: true)
        }
        let data = (try? JSONEncoder().encode(arguments)) ?? Data("{}".utf8)
        let reply = await MCPHost.shared.call(tool, argumentsJSON: data)
        return .init(content: reply.content.map(\.mcpContent), isError: reply.isError)
    }
}
