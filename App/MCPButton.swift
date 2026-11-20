import AppKit
import SwiftUI

/// The top bar's MCP button. Grey: off; a click starts the server on a free
/// localhost port. Green: listening; a click opens the panel with the key,
/// the address and the Claude Code setup command. Red: it could not start.
struct MCPButton: View {
    @State private var showsPanel = false
    private var service: MCPService { MCPService.shared }

    var body: some View {
        let colour = self.colour
        Button {
            if service.state == .off { service.start() } else { showsPanel.toggle() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(colour ?? Color(hex: 0x9CA3AF))
                    .frame(width: 8, height: 8)
                    .shadow(color: colour?.opacity(0.6) ?? .clear, radius: 3)
                Text("MCP")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(colour ?? Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(colour?.opacity(0.1) ?? Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(colour ?? Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            MCPPanel(close: { showsPanel = false })
        }
    }

    /// `nil` when off.
    private var colour: Color? {
        switch service.state {
        case .off: nil
        case .on: Color(hex: 0x16A34A)
        case .failed: Color(hex: 0xDC2626)
        }
    }

    private var help: String {
        switch service.state {
        case .off: "Start the MCP server so Claude Code can edit your projects"
        case .on: "MCP server listening. Click for the key and setup."
        case .failed: "The MCP server could not start. Click for details."
        }
    }
}

/// Key, address and setup command, and Turn Off.
private struct MCPPanel: View {
    let close: () -> Void
    @State private var showsKey = false
    private var service: MCPService { MCPService.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(label: "MCP SERVER", trailing: status)
            switch service.state {
            case .on(let port):
                running(port: port)
            case .failed(let message):
                InstrumentSection("Problem") {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("TRY AGAIN") { service.stop(); service.start() }
                        .buttonStyle(InstrumentButtonStyle(filled: true))
                }
            case .off:
                EmptyView()
            }
        }
        .frame(width: 420)
        .background(Instrument.background)
    }

    private var status: String {
        switch service.state {
        case .on: "LISTENING"
        case .failed: "ERROR"
        case .off: "OFF"
        }
    }

    @ViewBuilder private func running(port: UInt16) -> some View {
        InstrumentSection("Key", trailing: service.keyRequired ? "New key" : nil,
                          onTrailing: service.keyRequired ? { service.renewKey() } : nil) {
            Toggle("Require key", isOn: Binding(get: { service.keyRequired },
                                                set: { service.keyRequired = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            if service.keyRequired, let key = service.key {
                copyRow(showsKey ? key : String(repeating: "•", count: key.count), copying: key)
                Toggle("Show key", isOn: $showsKey)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Text("Claude Code sends this with every call; calls without it are refused. "
                     + "New key stops the old one working.")
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off: any program on this Mac can call TitleCut without a key.")
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        InstrumentSection("Folders") {
            ForEach(MCPFolders.builtIn, id: \.self) { folder in
                Text(folder.path)
                    .font(Instrument.mono(11))
                    .foregroundStyle(Instrument.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(folder.path)
                    .padding(8)
                    .background(Instrument.field, in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(MCPFolders.shared.folders, id: \.self) { folder in
                HStack(spacing: 8) {
                    Text(folder.path)
                        .font(Instrument.mono(11))
                        .foregroundStyle(Instrument.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(folder.path)
                    Button("REMOVE") { MCPFolders.shared.remove(folder) }
                        .buttonStyle(InstrumentButtonStyle(filled: false))
                }
                .padding(8)
                .background(Instrument.field, in: RoundedRectangle(cornerRadius: 6))
            }
            Button("ADD FOLDER…") { MCPFolders.shared.add() }
                .buttonStyle(InstrumentButtonStyle(filled: false))
            Text("macOS lets TitleCut open a file only once you have chosen it, in an "
                 + "Open panel or by dragging it in. Claude sends TitleCut a file's path, "
                 + "and macOS does not treat a path as your choice. Adding a folder here "
                 + "chooses everything in it at once, so Claude can open videos and songs "
                 + "there and save exports to it. Movies and Music are allowed from the "
                 + "start. Files you open yourself work from any folder.")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        InstrumentSection("Claude Code setup") {
            copyRow(service.setupCommand ?? "", copying: service.setupCommand ?? "")
            Text("Run once in a terminal, then start a new Claude Code session. When the key "
                 + "changes or is turned on or off, run `claude mcp remove titlecut` and this "
                 + "again.")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        InstrumentSection("Address") {
            copyRow(service.url ?? "", copying: service.url ?? "")
            Text("This Mac only (127.0.0.1), port \(String(port)).")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.muted)
            if let note = service.portNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("TURN OFF") {
                service.stop()
                close()
            }
            .buttonStyle(InstrumentButtonStyle(filled: false))
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(Instrument.divider).frame(height: 1) }
    }

    private func copyRow(_ shown: String, copying text: String) -> some View {
        HStack(spacing: 8) {
            Text(shown)
                .font(Instrument.mono(11))
                .foregroundStyle(Instrument.text)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("COPY") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(InstrumentButtonStyle(filled: false))
        }
        .padding(8)
        .background(Instrument.field, in: RoundedRectangle(cornerRadius: 6))
    }
}
