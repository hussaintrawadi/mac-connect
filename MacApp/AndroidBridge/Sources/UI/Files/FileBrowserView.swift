import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct FileBrowserView: View {
    @ObservedObject var fileSystem: FileSystemFeature
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\FileItem.name)]
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingItem: FileItem?
    @State private var renameText = ""
    @State private var deletingItem: FileItem?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            transferBar
        }
        .frame(minWidth: 650, minHeight: 450)
        .background(
            // Space previews the selected file, like Finder.
            Button("") { previewSelection() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        )
        .qlPreview($fileSystem.previewURL)
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                fileSystem.createFolder(named: newFolderName.isEmpty ? "New Folder" : newFolderName)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let item = renamingItem, !renameText.isEmpty {
                    fileSystem.rename(item: item, to: renameText)
                }
                renamingItem = nil
            }
            Button("Cancel", role: .cancel) { renamingItem = nil }
        }
        .confirmationDialog(
            "Delete “\(deletingItem?.name ?? "")” from your phone? This can’t be undone.",
            isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = deletingItem { fileSystem.delete(item: item) }
                deletingItem = nil
            }
            Button("Cancel", role: .cancel) { deletingItem = nil }
        }
        .onAppear {
            if fileSystem.entries.isEmpty {
                fileSystem.requestListing()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .onCopyCommand {
            // Cmd-C copies the selected files as download-on-demand promises;
            // Cmd-V in Finder pastes the real files.
            fileSystem.entries
                .filter { selection.contains($0.id) && !$0.isDirectory }
                .map { makeFilePromise(for: $0) }
        }
    }

    /// An NSItemProvider that downloads the file from the phone only when the
    /// drop/paste target actually asks for it (Finder, Desktop, etc.).
    private func makeFilePromise(for item: FileItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let ext = (item.name as NSString).pathExtension
        let utType = UTType(filenameExtension: ext) ?? .data
        provider.registerFileRepresentation(
            forTypeIdentifier: utType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            fileSystem.downloadToTemp(item: item) { url in
                if let url {
                    completion(url, false, nil)
                } else {
                    completion(nil, false, NSError(domain: "MacConnect", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Download failed"]))
                }
            }
            return nil
        }
        return provider
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.s3) {
            Button(action: { fileSystem.navigateUp() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(fileSystem.currentPath.isEmpty)
            .help("Go up one folder")

            Divider().frame(height: 16)

            breadcrumb

            Spacer(minLength: Theme.s3)

            Button {
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("New Folder")

            HStack(spacing: Theme.s1 + 2) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2)
                Text("Space to preview · drag in/out · ⌘C")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2 + 2)
        .frame(minHeight: 44)
        .background(.bar)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.s1) {
                let components = fileSystem.currentPath.split(separator: "/")
                Button {
                    fileSystem.requestListing(path: "")
                } label: {
                    Label("Device", systemImage: "iphone")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderless)

                ForEach(Array(components.enumerated()), id: \.offset) { idx, part in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Button(String(part)) {
                        let path = "/" + components.prefix(idx + 1).joined(separator: "/")
                        fileSystem.requestListing(path: path)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .fontWeight(idx == components.count - 1 ? .semibold : .regular)
                }
            }
        }
    }

    // MARK: - Content (empty state or table)

    @ViewBuilder
    private var content: some View {
        if fileSystem.entries.isEmpty {
            EmptyStateView(
                systemImage: "folder",
                title: "This Folder Is Empty",
                message: "Drag files here to send them to your phone, or browse another folder."
            )
            .background(Color(.textBackgroundColor))
        } else {
            fileTable
        }
    }

    // MARK: - File Table

    private var fileTable: some View {
        Table(fileSystem.entries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { item in
                if let thumb = item.thumbnail {
                    // Image/video preview sent by the phone
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: item.iconName)
                        .font(.system(size: 14))
                        .foregroundStyle(item.isDirectory ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: 22)
                }
            }
            .width(28)

            TableColumn("Name", value: \.name) { item in
                Text(item.name)
                    .fontWeight(item.isDirectory ? .medium : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onDrag {
                        // Files drag out to Finder as a download-on-demand promise.
                        item.isDirectory ? NSItemProvider() : makeFilePromise(for: item)
                    }
            }

            TableColumn("Size") { item in
                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)

            TableColumn("Modified") { item in
                Text(item.modifiedDate, style: .date)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .width(110)
        }
        .onChange(of: sortOrder) { newOrder in
            fileSystem.entries.sort(using: newOrder)
        }
        // Finder behavior: single-click selects (so Space/rename/delete work on
        // folders too); DOUBLE-click opens a folder or previews a file.
        .contextMenu(forSelectionType: String.self) { ids in
            let selected = fileSystem.entries.filter { ids.contains($0.id) }
            let files = selected.filter { !$0.isDirectory }
            if let folder = selected.first(where: { $0.isDirectory }), selected.count == 1 {
                Button("Open") {
                    fileSystem.requestListing(path: folder.path)
                    selection.removeAll()
                }
            }
            if files.count == 1 {
                Button("Preview") { fileSystem.preview(item: files[0]) }
            }
            if !files.isEmpty {
                Button("Save to Downloads") {
                    fileSystem.saveToDownloads(items: files)
                }
                Button("Save As…") {
                    let items = files
                    if items.count == 1 {
                        downloadSingleFile(items[0])
                    } else {
                        downloadSelectedItems(items)
                    }
                }
            }
            if selected.count == 1, let item = selected.first {
                Divider()
                Button("Rename…") {
                    renameText = item.name
                    renamingItem = item
                }
                Button("Delete", role: .destructive) {
                    deletingItem = item
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first,
                  let item = fileSystem.entries.first(where: { $0.id == id }) else { return }
            if item.isDirectory {
                fileSystem.requestListing(path: item.path)
                selection.removeAll()
            } else {
                fileSystem.preview(item: item)
            }
        }
    }

    private func previewSelection() {
        guard selection.count == 1,
              let id = selection.first,
              let item = fileSystem.entries.first(where: { $0.id == id }),
              !item.isDirectory else { return }
        fileSystem.preview(item: item)
    }

    // MARK: - Transfer Bar

    private var transferBar: some View {
        Group {
            let active = fileSystem.transfers.filter { $0.status == .inProgress }
            if !active.isEmpty {
                VStack(spacing: Theme.s2) {
                    ForEach(active) { transfer in
                        HStack(spacing: Theme.s3) {
                            Image(systemName: transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)

                            Text(transfer.fileName)
                                .font(.caption)
                                .lineLimit(1)

                            Spacer(minLength: Theme.s2)

                            ProgressView(value: transfer.progress)
                                .frame(width: 130)

                            Text("\(Int(transfer.progress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)

                            Button {
                                fileSystem.cancelTransfer(transfer.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Cancel transfer")
                        }
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2 + 2)
                .background(.bar)
            }
        }
    }

    // MARK: - Actions

    private func downloadSelected() {
        let items = fileSystem.entries.filter { selection.contains($0.id) && !$0.isDirectory }
        guard !items.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Download Here"

        guard panel.runModal() == .OK, let dir = panel.url else { return }

        for item in items {
            let dest = dir.appendingPathComponent(item.name)
            fileSystem.downloadFile(item: item, to: dest)
        }
    }

    private func downloadSelectedItems(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for item in items {
            fileSystem.downloadFile(item: item, to: dir.appendingPathComponent(item.name))
        }
    }

    private func downloadSingleFile(_ item: FileItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.prompt = "Download"

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        fileSystem.downloadFile(item: item, to: dest)
    }

    private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            fileSystem.uploadFile(from: url, toPath: fileSystem.currentPath)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                DispatchQueue.main.async {
                    fileSystem.uploadFile(from: url, toPath: fileSystem.currentPath)
                }
            }
        }
    }
}

// MARK: - Double-click support

extension View {
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        self.gesture(TapGesture(count: 2).onEnded(action))
    }
}

// MARK: - Quick Look helper

extension View {
    /// Quick Look on macOS 14+; on macOS 13 falls back to opening the file
    /// with its default app when the URL is set.
    @ViewBuilder
    func qlPreview(_ url: Binding<URL?>) -> some View {
        if #available(macOS 14.0, *) {
            self.quickLookPreview(url)
        } else {
            self.onChange(of: url.wrappedValue) { newValue in
                if let newValue {
                    NSWorkspace.shared.open(newValue)
                    url.wrappedValue = nil
                }
            }
        }
    }
}
