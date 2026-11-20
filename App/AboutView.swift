import SwiftUI

/// About window: version, build number, build date, DEV/PROD badge.
struct AboutView: View {
    static let windowID = "about"

    let info: BuildInfo

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            HStack(spacing: 8) {
                Text(info.displayName)
                    .font(.title2.bold())
                Text(info.badge)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(info.isDevelopment ? Color.orange : Color.green,
                                in: RoundedRectangle(cornerRadius: 4))
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Version").foregroundStyle(.secondary)
                    Text(info.version)
                }
                GridRow {
                    Text("Build").foregroundStyle(.secondary)
                    Text(info.build)
                }
                GridRow {
                    Text("Built").foregroundStyle(.secondary)
                    Text(info.buildDate.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "Unknown")
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
