import Foundation
import AppKit
import Combine
import os

final class GalleryFeature: ObservableObject {
    @Published var items: [GalleryPhoto] = []
    @Published var totalCount: Int = 0
    @Published var isLoading = false

    // Albums (folders)
    @Published var albums: [GalleryAlbumItem] = []
    @Published var currentAlbumId: String?      // nil = album list view
    @Published var currentAlbumName: String = ""

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Gallery")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    private let pageSize = 60
    private var requestedOffsets = Set<Int>()

    /// Show the album/folder list first.
    func loadInitial() {
        guard albums.isEmpty else { return }
        loadAlbums()
    }

    func loadAlbums() {
        DispatchQueue.main.async { self.isLoading = true }
        var env = ABEnvelope()
        env.galleryAlbumsRequest = ABGalleryAlbumsRequest()
        onSendEnvelope?(env)
        logger.info("Requested gallery albums")
    }

    /// Open a folder and load its photos.
    func openAlbum(_ album: GalleryAlbumItem) {
        DispatchQueue.main.async {
            self.currentAlbumId = album.id
            self.currentAlbumName = album.name
            self.items = []
        }
        requestedOffsets.removeAll()
        requestPage(offset: 0)
    }

    /// Back to the album list.
    func closeAlbum() {
        DispatchQueue.main.async {
            self.currentAlbumId = nil
            self.items = []
        }
        requestedOffsets.removeAll()
    }

    func refresh() {
        requestedOffsets.removeAll()
        if currentAlbumId == nil {
            DispatchQueue.main.async { self.albums = [] }
            loadAlbums()
        } else {
            DispatchQueue.main.async { self.items = [] }
            requestPage(offset: 0)
        }
    }

    /// Request the next page when the user scrolls near the end.
    func loadMoreIfNeeded(currentItem: GalleryPhoto) {
        guard let idx = items.firstIndex(where: { $0.id == currentItem.id }) else { return }
        if idx >= items.count - 12, items.count < totalCount {
            requestPage(offset: items.count)
        }
    }

    private func requestPage(offset: Int) {
        guard !requestedOffsets.contains(offset) else { return }
        requestedOffsets.insert(offset)

        DispatchQueue.main.async { self.isLoading = true }

        var req = ABGalleryRequest()
        req.offset = Int32(offset)
        req.limit = Int32(pageSize)
        req.bucketID = currentAlbumId ?? ""
        var env = ABEnvelope()
        env.galleryRequest = req
        onSendEnvelope?(env)
        logger.info("Requested gallery page at offset \(offset) album \(self.currentAlbumId ?? "all")")
    }

    func handleAlbumsResponse(_ resp: ABGalleryAlbumsResponse) {
        let newAlbums = resp.albums.map { GalleryAlbumItem(proto: $0) }
        DispatchQueue.main.async {
            self.albums = newAlbums
            self.isLoading = false
        }
        logger.info("Received \(newAlbums.count) albums")
    }

    func handleResponse(_ resp: ABGalleryResponse) {
        let newItems = resp.items.map { GalleryPhoto(proto: $0) }
        DispatchQueue.main.async {
            self.totalCount = Int(resp.totalCount)
            if resp.offset == 0 {
                self.items = newItems
            } else {
                let existing = Set(self.items.map { $0.id })
                self.items.append(contentsOf: newItems.filter { !existing.contains($0.id) })
            }
            self.isLoading = false
        }
        logger.info("Received \(newItems.count) photos (total \(resp.totalCount))")
    }
}

struct GalleryAlbumItem: Identifiable {
    let id: String
    let name: String
    let count: Int
    let cover: NSImage?

    init(proto: ABGalleryAlbum) {
        id = proto.id
        name = proto.name
        count = Int(proto.count)
        cover = proto.coverThumbnail.isEmpty ? nil : NSImage(data: proto.coverThumbnail)
    }
}

struct GalleryPhoto: Identifiable {
    let id: String
    let path: String
    let name: String
    let date: Date
    let sizeBytes: Int64
    let isVideo: Bool
    let thumbnail: NSImage?
    let width: Int
    let height: Int

    init(proto: ABGalleryItem) {
        id = proto.id
        path = proto.path
        name = proto.name
        date = Date(timeIntervalSince1970: Double(proto.dateTakenMs) / 1000)
        sizeBytes = proto.sizeBytes
        isVideo = proto.isVideo
        width = Int(proto.width)
        height = Int(proto.height)
        thumbnail = proto.thumbnail.isEmpty ? nil : NSImage(data: proto.thumbnail)
    }

    /// Build a FileItem so the existing file-download path can fetch full-res.
    var asFileItem: FileItem {
        FileItem(
            name: name,
            path: path,
            isDirectory: false,
            sizeBytes: sizeBytes,
            modifiedDate: date,
            mimeType: isVideo ? "video/mp4" : "image/jpeg"
        )
    }
}
