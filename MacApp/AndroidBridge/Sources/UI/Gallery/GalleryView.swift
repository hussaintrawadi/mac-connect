import SwiftUI

struct GalleryView: View {
    @ObservedObject var gallery: GalleryFeature
    @ObservedObject var fileSystem: FileSystemFeature

    @State private var selection: GalleryPhoto?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: Theme.s1)]

    private let albumColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if gallery.currentAlbumId == nil {
                albumsView
            } else {
                photosView
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { gallery.loadInitial() }
    }

    private var header: some View {
        WindowHeader(
            title: gallery.currentAlbumId == nil ? "Photos" : gallery.currentAlbumName,
            systemImage: gallery.currentAlbumId == nil ? "photo.on.rectangle" : "rectangle.stack"
        ) {
            HStack(spacing: Theme.s3) {
                if gallery.currentAlbumId != nil {
                    Button { gallery.closeAlbum() } label: {
                        Label("Albums", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }
                if let sel = selection {
                    Button { save(sel) } label: {
                        Label("Save", systemImage: "arrow.down.circle")
                    }
                    .help("Save the selected photo to Downloads")
                }
                if gallery.isLoading { ProgressView().controlSize(.small) }
                Button { gallery.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

    // MARK: - Albums (folders)

    private var albumsView: some View {
        Group {
            if gallery.albums.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.stack",
                    title: gallery.isLoading ? "Loading Albums…" : "No Albums",
                    message: gallery.isLoading ? nil : "Your phone's photo folders will appear here.",
                    isLoading: gallery.isLoading
                )
                .background(Color(.textBackgroundColor))
            } else {
                ScrollView {
                    LazyVGrid(columns: albumColumns, spacing: 16) {
                        ForEach(gallery.albums) { album in
                            AlbumCard(album: album)
                                .onTapGesture { gallery.openAlbum(album) }
                        }
                    }
                    .padding(16)
                }
                .background(Color(.textBackgroundColor))
            }
        }
    }

    // MARK: - Photos (inside an album)

    private var photosView: some View {
        Group {
            if gallery.items.isEmpty {
                EmptyStateView(
                    systemImage: "photo.stack",
                    title: gallery.isLoading ? "Loading Photos…" : "No Photos",
                    message: nil,
                    isLoading: gallery.isLoading
                )
                .background(Color(.textBackgroundColor))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Theme.s1) {
                        ForEach(gallery.items) { photo in
                            GalleryThumbnail(photo: photo, isSelected: selection?.id == photo.id)
                                .onTapGesture { selection = photo }
                                .onTapGesture(count: 2) { save(photo) }
                                .onAppear { gallery.loadMoreIfNeeded(currentItem: photo) }
                                .contextMenu {
                                    Button("Save to Downloads") { save(photo) }
                                }
                        }
                    }
                    .padding(Theme.s2)
                }
                .background(Color(.textBackgroundColor))
            }
        }
    }

    private func save(_ photo: GalleryPhoto) {
        fileSystem.saveToDownloads(items: [photo.asFileItem])
    }
}

// MARK: - Album (folder) card

struct AlbumCard: View {
    let album: GalleryAlbumItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Size the cell with Color.clear and overlay the image — a .fill image
            // otherwise expands the grid cell's layout and bleeds across columns.
            Color.clear
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let cover = album.cover {
                        Image(nsImage: cover)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(.controlBackgroundColor))
                            .overlay(
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2)
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .strokeBorder(Theme.hairline(hovering), lineWidth: 1)
                )

            Text(album.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
            Text("\(album.count) item\(album.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: Theme.smallRadius + 4, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .scaleEffect(hovering ? 0.99 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct GalleryThumbnail: View {
    let photo: GalleryPhoto
    let isSelected: Bool

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 150, height: 150)
                .overlay {
                    if let thumb = photo.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(.controlBackgroundColor))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))

            if photo.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .padding(6)
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Theme.hairline(hovering),
                              lineWidth: isSelected ? 3 : 1)
        )
        .scaleEffect(hovering && !isSelected ? 0.98 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
