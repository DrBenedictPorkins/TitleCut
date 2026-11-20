import AppKit
import Foundation
import MCP
import TitleCutCore

/// Routes MCP tool calls to the open projects (§10). Each document window
/// registers an `MCPSession`; a call goes to the one its `project` argument
/// names, by ID or name, which is required when more than one is open.
@MainActor
final class MCPHost {
    static let shared = MCPHost()

    private var sessions: [WeakSession] = []

    private struct WeakSession {
        weak var session: MCPSession?
    }

    func register(_ session: MCPSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
        sessions.append(WeakSession(session: session))
    }

    /// Renews `session`'s project ID if another open project has it: a file
    /// copied in the Finder carries its original's ID.
    func ensureUniqueID(_ session: MCPSession) {
        let others = sessions.compactMap(\.session).filter { $0 !== session }
        if others.contains(where: { $0.project.id == session.project.id }) {
            session.renewProjectID()
        }
    }

    func unregister(_ session: MCPSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
    }

    /// Open projects, front window first.
    var orderedSessions: [MCPSession] {
        let live = sessions.compactMap(\.session)
        let order = NSApp.orderedWindows
        return live.sorted { a, b in
            let ia = a.window.flatMap { order.firstIndex(of: $0) } ?? .max
            let ib = b.window.flatMap { order.firstIndex(of: $0) } ?? .max
            return ia < ib
        }
    }

    // MARK: Requests

    /// Runs one tool call; `argumentsJSON` is the call's arguments object.
    func call(_ tool: String, argumentsJSON: Data) async -> MCPReply {
        let arguments = (try? JSONDecoder().decode(JSONValue.self, from: argumentsJSON))?
            .objectValue ?? [:]
        return await handle(tool, MCPArguments(arguments))
    }

    private func handle(_ tool: String, _ arguments: MCPArguments) async -> MCPReply {
        switch tool {
        case "list_projects":
            return .json(orderedSessions.map { session in
                JSONValue.object(["id": .string(session.project.id.uuidString),
                                  "name": .string(session.name()),
                                  "has_video": .bool(session.store.project.source != nil),
                                  "saved": .bool(!session.isEdited())])
            })
        case "new_project":
            NSDocumentController.shared.newDocument(nil)
            return .text("A new untitled project opened in front. Call open_video next.")
        default:
            break
        }
        let sessions = orderedSessions
        guard !sessions.isEmpty else {
            return .error("No project is open in TitleCut. Call new_project, or open one.")
        }
        let session: MCPSession
        if let key = arguments.string("project") {
            if let id = UUID(uuidString: key) {
                guard let match = sessions.first(where: { $0.project.id == id }) else {
                    return .error("No open project has the ID \(key). Open projects: "
                                  + Self.describe(sessions) + ".")
                }
                session = match
            } else {
                let matches = sessions.filter {
                    $0.name().localizedCaseInsensitiveCompare(key) == .orderedSame
                }
                guard matches.count == 1 else {
                    return .error((matches.isEmpty ? "No open project is named \(key)."
                                   : "\(matches.count) open projects are named \(key); pass "
                                     + "the ID instead.")
                                  + " Open projects: " + Self.describe(sessions) + ".")
                }
                session = matches[0]
            }
        } else if sessions.count == 1 {
            session = sessions[0]
        } else {
            // Several open: guessing the front window risks editing the wrong one.
            return .error("\(sessions.count) projects are open. Pass `project` with the ID "
                          + "of one: " + Self.describe(sessions) + ".")
        }
        return await session.handle(tool, arguments)
    }

    /// `Name (ID), …` for error messages.
    private static func describe(_ sessions: [MCPSession]) -> String {
        sessions.map { "\($0.name()) (\($0.project.id.uuidString))" }
            .joined(separator: ", ")
    }
}

/// One tool result: text or a PNG, flagged as an error or not.
struct MCPReply {
    enum Content {
        case text(String)
        case png(Data)

        var mcpContent: Tool.Content {
            switch self {
            case .text(let text): .text(text)
            case .png(let data): .image(data: data.base64EncodedString(), mimeType: "image/png")
            }
        }
    }

    var isError: Bool
    var content: [Content]

    static func text(_ text: String) -> MCPReply { MCPReply(isError: false, content: [.text(text)]) }
    static func error(_ text: String) -> MCPReply { MCPReply(isError: true, content: [.text(text)]) }

    /// `value` as pretty JSON text.
    static func json(_ value: JSONValue) -> MCPReply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        return .text(text ?? "null")
    }

    static func json(_ values: [JSONValue]) -> MCPReply { json(.array(values)) }
}

/// Any JSON value, for reading tool arguments and writing results.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    /// Seconds from ticks, rounded to milliseconds.
    static func seconds(_ ticks: Tick) -> JSONValue {
        .number((Ticks.seconds(ticks) * 1000).rounded() / 1000)
    }
}

/// A tool call's arguments, with typed accessors.
struct MCPArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func has(_ key: String) -> Bool { values[key] != nil && values[key] != .null }

    func string(_ key: String) -> String? {
        if case .string(let value)? = values[key] { value } else { nil }
    }

    func number(_ key: String) -> Double? {
        switch values[key] {
        case .number(let value)?: value
        case .string(let value)?: Double(value)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let value)? = values[key] { value } else { nil }
    }

    func strings(_ key: String) -> [String]? {
        switch values[key] {
        case .array(let items)?:
            items.compactMap { if case .string(let value) = $0 { value } else { nil } }
        case .string(let value)?: [value]
        default: nil
        }
    }

    func id(_ key: String) -> UUID? { string(key).flatMap(UUID.init(uuidString:)) }

    func ticks(_ key: String) -> Tick? { number(key).map { Ticks.from(seconds: $0) } }
}
