import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AirDrop-style "Send to Phone": drop files (or pick them) and they stream to the
/// phone's Downloads. Also shows recent transfers in both directions.
struct AirDropSendView: View {
    @ObservedObject var fileSystem: FileSystemFeature
    let onFiles: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            if !fileSystem.transfers.isEmpty { transfersList }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 380, minHeight: 340)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
            VStack(spacing: 10) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Text("Drop files to send to your phone")
                    .font(.headline)
                Text("They’ll land in the phone’s Downloads folder")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Choose Files…") { pick() }
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .padding()
        }
        .frame(height: 220)
        .background(targeted ? Color.accentColor.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadURLs(from: providers)
            return true
        }
    }

    private var transfersList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent transfers").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(fileSystem.transfers.reversed()) { t in
                        HStack(spacing: 10) {
                            Image(systemName: t.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .foregroundStyle(t.direction == .upload ? AnyShapeStyle(.blue) : AnyShapeStyle(.green))
                            Text(t.fileName).lineLimit(1)
                            Spacer()
                            Text(statusText(t)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    private func statusText(_ t: FileTransfer) -> String {
        switch t.status {
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .inProgress:
            guard t.totalBytes > 0 else { return "Sending…" }
            let pct = Int(Double(t.transferredBytes) / Double(t.totalBytes) * 100)
            return "\(pct)%"
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            onFiles(panel.urls)
        }
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        for p in providers {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let u = item as? URL { url = u }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let url {
                    DispatchQueue.main.async { onFiles([url]) }
                }
            }
        }
    }
}
