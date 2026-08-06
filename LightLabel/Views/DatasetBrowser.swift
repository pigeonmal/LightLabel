import AppKit
import ImageIO
import SwiftUI

struct DatasetGrid: View {
    @Bindable var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.filteredImages, id: \.id) { image in
                    ImageCard(model: model, image: image)
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if model.filteredImages.isEmpty { ContentUnavailableView.search(text: model.searchText) } }
        .navigationTitle(model.dataset?.name ?? "Dataset")
    }
}

struct DatasetList: View {
    @Bindable var model: AppModel

    var body: some View {
        Table(model.filteredImages, selection: Binding<UUID?>(get: { model.selectedImageID }, set: { id in model.selectImage(id) })) {
            TableColumn("Image") { image in
                HStack(spacing: 10) {
                    ThumbnailView(url: model.imageURL(for: image), maxPixelSize: 64)
                        .frame(width: 52, height: 38).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(image.fileName).lineLimit(1)
                }
            }
            TableColumn("Size") { image in
                Text("\(image.size.width) × \(image.size.height)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            TableColumn("Split") { image in Text(String(describing: image.split).capitalized) }
            TableColumn("Labels") { image in
                Text(annotationCount(image.id), format: .number).monospacedDigit()
            }
            TableColumn("Review") { image in Text(String(describing: image.reviewState).capitalized) }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let image = model.dataset?.images.first(where: { $0.id == id }), let url = model.imageURL(for: image) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        } primaryAction: { ids in
            model.selectImage(ids.first)
            model.browserMode = .workspace
        }
        .overlay { if model.filteredImages.isEmpty { ContentUnavailableView.search(text: model.searchText) } }
        .navigationTitle(model.dataset?.name ?? "Dataset")
    }

    private func annotationCount(_ imageID: UUID) -> Int {
        model.annotationCount(for: imageID)
    }
}

private struct ImageCard: View {
    let model: AppModel
    let image: DatasetImage

    var body: some View {
        Button {
            model.selectImage(image.id)
            model.browserMode = .workspace
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    ThumbnailView(url: model.imageURL(for: image), maxPixelSize: 520)
                        .frame(maxWidth: .infinity).aspectRatio(4 / 3, contentMode: .fit)
                        .background(Color(nsColor: .underPageBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    Text(String(describing: image.split).uppercased())
                        .font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule()).padding(7)
                }
                Text(image.fileName).fontWeight(.medium).lineLimit(1)
                HStack {
                    Label(annotationCount.formatted(), systemImage: "rectangle.dashed")
                    Spacer()
                    Label(String(describing: image.reviewState).capitalized, systemImage: reviewSymbol)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(image.fileName), \(annotationCount) annotations")
    }

    private var annotationCount: Int {
        model.annotationCount(for: image.id)
    }

    private var reviewSymbol: String {
        String(describing: image.reviewState).localizedCaseInsensitiveContains("reviewed") ? "checkmark.circle.fill" : "circle"
    }
}

struct ThumbnailView: View {
    let url: URL?
    let maxPixelSize: Int
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { failed = true; return }
            image = await ThumbnailStore.shared.image(at: url, maxPixelSize: maxPixelSize)
            failed = image == nil
        }
    }
}

actor ThumbnailStore {
    static let shared = ThumbnailStore()
    private init() {}

    func image(at url: URL, maxPixelSize: Int) async -> NSImage? {
        guard let cgImage = try? await ImageLoader.shared.thumbnail(at: url, maximumPixelSize: maxPixelSize) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
