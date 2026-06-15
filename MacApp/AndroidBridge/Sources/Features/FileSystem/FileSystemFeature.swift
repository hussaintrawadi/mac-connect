import Foundation
import AppKit
import Combine
import CryptoKit
import os

final class FileSystemFeature: ObservableObject {
    @Published var currentPath: String = ""
    @Published var entries: [FileItem] = []
    @Published var pathHistory: [String] = []
    @Published var transfers: [FileTransfer] = []

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "FileSystem")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    private var activeDownloads: [String: DownloadState] = [:]
    private var activeUploads: [String: UploadState] = [:]
    private var revealOnComplete: Set<String> = []
    private var downloadCompletions: [String: (URL?) -> Void] = [:]

    /// Download a file to a temp location and call back with its URL — used for
    /// drag-out to Finder (NSItemProvider file promise) and Cmd-C.
    func downloadToTemp(item: FileItem, completion: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacConnectDrops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(item.name)

        // Cache hit: same name and exact size already downloaded — reuse it.
        // This is what makes repeated previews (Space) instant.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let size = attrs[.size] as? Int64, size == item.sizeBytes, size > 0 {
            completion(dest)
            return
        }

        let transferId = UUID().uuidString
        downloadCompletions[transferId] = completion
        activeDownloads[transferId] = DownloadState(destination: dest, expectedSize: item.sizeBytes, chunks: [])

        var request = ABFileDownloadRequest()
        request.path = item.path
        request.transferID = transferId
        var envelope = ABEnvelope()
        envelope.fileDownloadRequest = request
        onSendEnvelope?(envelope)
        logger.info("Drag-out download started: \(item.name)")
    }

    // MARK: - Browse

    func requestListing(path: String = "") {
        var request = ABFileListRequest()
        request.path = path

        var envelope = ABEnvelope()
        envelope.fileListRequest = request
        onSendEnvelope?(envelope)

        logger.info("Requested listing: \(path.isEmpty ? "(root)" : path)")
    }

    func handleListResponse(_ response: ABFileListResponse) {
        let items = response.entries.map { entry in
            FileItem(
                name: entry.name,
                path: entry.path,
                isDirectory: entry.isDirectory,
                sizeBytes: entry.sizeBytes,
                modifiedDate: Date(timeIntervalSince1970: Double(entry.modifiedMs) / 1000),
                mimeType: entry.mimeType,
                thumbnail: entry.thumbnail.isEmpty ? nil : NSImage(data: entry.thumbnail)
            )
        }

        DispatchQueue.main.async {
            self.currentPath = response.path
            self.entries = items
            if !self.pathHistory.contains(response.path) || self.pathHistory.last != response.path {
                self.pathHistory.append(response.path)
            }
        }

        logger.info("Received \(items.count) entries for \(response.path)")
    }

    // MARK: - Finder-style operations

    func createFolder(named name: String) {
        var op = ABFileOperation()
        op.op = .createDir
        op.path = currentPath
        op.name = name
        sendOperation(op)
    }

    func rename(item: FileItem, to newName: String) {
        var op = ABFileOperation()
        op.op = .rename
        op.path = item.path
        op.name = newName
        sendOperation(op)
    }

    func delete(item: FileItem) {
        var op = ABFileOperation()
        op.op = .delete
        op.path = item.path
        sendOperation(op)
    }

    private func sendOperation(_ op: ABFileOperation) {
        var env = ABEnvelope()
        env.fileOperation = op
        onSendEnvelope?(env)
    }

    func handleOperationResult(_ result: ABFileOperationResult) {
        if !result.success {
            logger.warning("File operation failed: \(result.error)")
        }
        // Refresh whichever directory changed.
        requestListing(path: result.parentPath.isEmpty ? currentPath : result.parentPath)
    }

    // MARK: - Quick Look preview

    @Published var previewURL: URL?

    /// Download the file to a temp location and present it with Quick Look.
    func preview(item: FileItem) {
        guard !item.isDirectory else { return }
        downloadToTemp(item: item) { [weak self] url in
            DispatchQueue.main.async { self?.previewURL = url }
        }
    }

    func navigateUp() {
        guard !currentPath.isEmpty else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        requestListing(path: parent)
    }

    // MARK: - Download

    /// Convenience: download each file to ~/Downloads and reveal it in Finder when done.
    func saveToDownloads(items: [FileItem]) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        for item in items where !item.isDirectory {
            let dest = uniqueDestination(downloads.appendingPathComponent(item.name))
            downloadFile(item: item, to: dest, revealWhenDone: true)
        }
    }

    private func uniqueDestination(_ url: URL) -> URL {
        var candidate = url
        let fm = FileManager.default
        var counter = 1
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = dir.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    func downloadFile(item: FileItem, to destination: URL, revealWhenDone: Bool = false) {
        let transferId = UUID().uuidString
        if revealWhenDone { revealOnComplete.insert(transferId) }

        var request = ABFileDownloadRequest()
        request.path = item.path
        request.transferID = transferId

        let transfer = FileTransfer(
            id: transferId,
            fileName: item.name,
            totalBytes: item.sizeBytes,
            direction: .download
        )

        activeDownloads[transferId] = DownloadState(
            destination: destination,
            expectedSize: item.sizeBytes,
            chunks: []
        )

        DispatchQueue.main.async {
            self.transfers.append(transfer)
        }

        var envelope = ABEnvelope()
        envelope.fileDownloadRequest = request
        onSendEnvelope?(envelope)

        logger.info("Download started: \(item.name) → \(destination.path)")
    }

    func handleFileChunk(_ chunk: ABFileChunk) {
        if let download = activeDownloads[chunk.transferID] {
            handleDownloadChunk(chunk, download: download)
        }
    }

    private func handleDownloadChunk(_ chunk: ABFileChunk, download: DownloadState) {
        var dl = download
        if !chunk.data.isEmpty {
            dl.chunks.append(chunk.data)
            dl.receivedBytes += Int64(chunk.data.count)
        }
        activeDownloads[chunk.transferID] = dl

        DispatchQueue.main.async {
            if let idx = self.transfers.firstIndex(where: { $0.id == chunk.transferID }) {
                self.transfers[idx].transferredBytes = dl.receivedBytes
            }
        }

        if chunk.isLast {
            writeDownload(transferId: chunk.transferID, state: dl)
        }
    }

    private func writeDownload(transferId: String, state: DownloadState) {
        do {
            var allData = Data()
            for chunk in state.chunks {
                allData.append(chunk)
            }

            try allData.write(to: state.destination)
            activeDownloads.removeValue(forKey: transferId)

            let shouldReveal = revealOnComplete.contains(transferId)
            revealOnComplete.remove(transferId)
            let completion = downloadCompletions.removeValue(forKey: transferId)

            DispatchQueue.main.async {
                if let idx = self.transfers.firstIndex(where: { $0.id == transferId }) {
                    self.transfers[idx].status = .completed
                }
                if shouldReveal {
                    NSWorkspace.shared.activateFileViewerSelecting([state.destination])
                }
                completion?(state.destination)
            }

            logger.info("Download saved: \(state.destination.lastPathComponent) (\(allData.count) bytes)")
        } catch {
            logger.error("Download write failed: \(error.localizedDescription)")
            let completion = downloadCompletions.removeValue(forKey: transferId)
            DispatchQueue.main.async {
                if let idx = self.transfers.firstIndex(where: { $0.id == transferId }) {
                    self.transfers[idx].status = .failed(error.localizedDescription)
                }
                completion?(nil)
            }
        }
    }

    // MARK: - Upload

    func uploadFile(from source: URL, toPath destinationPath: String, shareAfter: Bool = false) {
        guard let data = try? Data(contentsOf: source) else {
            logger.error("Cannot read file: \(source.path)")
            return
        }

        let transferId = UUID().uuidString
        let fileName = source.lastPathComponent

        var request = ABFileUploadRequest()
        request.destinationPath = destinationPath
        request.fileName = fileName
        request.totalSize = Int64(data.count)
        request.transferID = transferId
        request.shareAfter = shareAfter

        var envelope = ABEnvelope()
        envelope.fileUploadRequest = request
        onSendEnvelope?(envelope)

        let transfer = FileTransfer(
            id: transferId,
            fileName: fileName,
            totalBytes: Int64(data.count),
            direction: .upload
        )

        DispatchQueue.main.async {
            self.transfers.append(transfer)
        }

        // Send chunks on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.sendChunks(transferId: transferId, data: data)
        }

        logger.info("Upload started: \(fileName) (\(data.count) bytes)")
    }

    private func sendChunks(transferId: String, data: Data) {
        let chunkSize = 64 * 1024
        var offset = 0
        var chunkIndex: UInt32 = 0

        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunkData = data[offset..<end]
            let isLast = end >= data.count

            var chunk = ABFileChunk()
            chunk.transferID = transferId
            chunk.chunkIndex = chunkIndex
            chunk.data = chunkData
            chunk.isLast = isLast

            var envelope = ABEnvelope()
            envelope.fileChunk = chunk
            onSendEnvelope?(envelope)

            offset = end
            chunkIndex += 1

            DispatchQueue.main.async {
                if let idx = self.transfers.firstIndex(where: { $0.id == transferId }) {
                    self.transfers[idx].transferredBytes = Int64(offset)
                }
            }
        }

        logger.info("Upload chunks sent: \(chunkIndex) chunks for \(transferId)")
    }

    // MARK: - Transfer Control

    func handleTransferComplete(_ complete: ABFileTransferComplete) {
        activeDownloads.removeValue(forKey: complete.transferID)

        DispatchQueue.main.async {
            if let idx = self.transfers.firstIndex(where: { $0.id == complete.transferID }) {
                self.transfers[idx].status = .completed
            }
        }

        logger.info("Transfer complete: \(complete.transferID)")
    }

    func handleTransferCancel(_ cancel: ABFileTransferCancel) {
        activeDownloads.removeValue(forKey: cancel.transferID)

        DispatchQueue.main.async {
            if let idx = self.transfers.firstIndex(where: { $0.id == cancel.transferID }) {
                self.transfers[idx].status = .failed(cancel.reason)
            }
        }

        logger.warning("Transfer cancelled: \(cancel.reason)")
    }

    func cancelTransfer(_ transferId: String) {
        var cancel = ABFileTransferCancel()
        cancel.transferID = transferId
        cancel.reason = "Cancelled by user"

        var envelope = ABEnvelope()
        envelope.fileTransferCancel = cancel
        onSendEnvelope?(envelope)

        activeDownloads.removeValue(forKey: transferId)
        activeUploads.removeValue(forKey: transferId)

        DispatchQueue.main.async {
            if let idx = self.transfers.firstIndex(where: { $0.id == transferId }) {
                self.transfers[idx].status = .cancelled
            }
        }
    }
}

// MARK: - Models

struct FileItem: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let modifiedDate: Date
    let mimeType: String
    var thumbnail: NSImage? = nil

    var id: String { path }

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        switch mimeType {
        case let m where m.hasPrefix("image/"): return "photo"
        case let m where m.hasPrefix("video/"): return "film"
        case let m where m.hasPrefix("audio/"): return "music.note"
        case let m where m.hasPrefix("text/"): return "doc.text"
        case "application/pdf": return "doc.richtext"
        case "application/zip", "application/x-tar", "application/gzip": return "doc.zipper"
        default: return "doc"
        }
    }
}

struct FileTransfer: Identifiable {
    let id: String
    let fileName: String
    let totalBytes: Int64
    let direction: Direction
    var transferredBytes: Int64 = 0
    var status: TransferStatus = .inProgress

    enum Direction { case download, upload }
    enum TransferStatus: Equatable {
        case inProgress, completed, cancelled
        case failed(String)
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }
}

private struct DownloadState {
    let destination: URL
    let expectedSize: Int64
    var chunks: [Data] = []
    var receivedBytes: Int64 = 0
}

private struct UploadState {
    let source: URL
    let totalSize: Int64
}
