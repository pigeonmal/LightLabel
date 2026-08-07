import AppKit
import ImageIO
import SwiftUI

struct DatasetGrid: View {
    @Bindable var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.browserImages, id: \.id) { image in
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
    @State private var sortOrder = [KeyPathComparator<DatasetListRow>(\.fileName)]
    @State private var tableRows: [DatasetListRow] = []

    var body: some View {
        Table(tableRows, selection: Binding<Set<UUID>>(get: { model.selectedImageIDs }, set: { ids in model.selectImages(ids) }), sortOrder: tableSortOrder) {
            TableColumn("Name", value: \.fileName) { row in
                HStack(spacing: 10) {
                    ThumbnailView(url: model.imageURL(for: row.image), maxPixelSize: 64)
                        .frame(width: 52, height: 38).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(row.fileName).lineLimit(1)
                }
            }
            TableColumn("Size", value: \.pixelArea) { row in
                Text("\(row.image.size.width) × \(row.image.size.height)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            TableColumn("Split", value: \.splitRank) { row in Text(row.splitTitle) }
            TableColumn("Labels", value: \.labelCount) { row in
                Text(row.labelCount, format: .number).monospacedDigit()
            }
        }
        // Header sorting is a data refresh, not a visual animation. Avoid
        // animating thousands of table rows when the user clicks a column.
        .transaction { transaction in transaction.animation = nil }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                if let id = ids.first, let image = model.dataset?.images.first(where: { $0.id == id }), let url = model.imageURL(for: image) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Menu("Set Split") {
                    ForEach([DatasetSplit.train, .validation, .test, .unassigned], id: \.self) { split in
                        Button(split == .unassigned ? "Unassigned" : split.yoloName.capitalized) { model.setSplit(split, for: ids) }
                    }
                }
                Divider()
                Button("Trash \(ids.count == 1 ? "Image" : "Images")", role: .destructive) { model.deleteImages(ids: ids) }
            }
        } primaryAction: { ids in
            model.selectImages(ids)
            model.browserMode = .workspace
        }
        .overlay { if model.filteredImages.isEmpty { ContentUnavailableView.search(text: model.searchText) } }
        .navigationTitle(model.dataset?.name ?? "Dataset")
        .task(id: model.browserDataRevision) {
            rebuildTableRows()
        }
    }

    private var tableSortOrder: Binding<[KeyPathComparator<DatasetListRow>]> {
        Binding(
            get: { sortOrder },
            set: { newOrder in
                sortOrder = newOrder
                tableRows.sort(using: newOrder)
            }
        )
    }

    private func rebuildTableRows() {
        var rows = model.filteredImages.map { DatasetListRow(image: $0, labelCount: model.annotationCount(for: $0.id)) }
        rows.sort(using: sortOrder)
        tableRows = rows
    }
}

private struct DatasetListRow: Identifiable {
    let image: DatasetImage
    let fileName: String
    let pixelArea: Int64
    let splitRank: Int
    let splitTitle: String
    let labelCount: Int

    var id: UUID { image.id }
    init(image: DatasetImage, labelCount: Int) {
        self.image = image
        self.fileName = image.fileName
        self.pixelArea = Int64(image.size.width) * Int64(image.size.height)
        self.splitRank = Self.rank(for: image.split)
        self.splitTitle = image.split == .unassigned ? "Unassigned" : image.split.yoloName.capitalized
        self.labelCount = labelCount
    }

    private static func rank(for split: DatasetSplit) -> Int {
        switch split {
        case .train: 0
        case .validation: 1
        case .test: 2
        case .unassigned: 3
        }
    }
}

private struct ImageCard: View {
    let model: AppModel
    let image: DatasetImage

    var body: some View {
        Button {
            let modifiers = NSEvent.modifierFlags
            model.selectImage(image.id, modifiers: modifiers)
            if !modifiers.contains(.command) && !modifiers.contains(.shift) { model.browserMode = .workspace }
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
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = model.imageURL(for: image) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Menu("Set Split") {
                ForEach([DatasetSplit.train, .validation, .test, .unassigned], id: \.self) { split in
                    Button(split == .unassigned ? "Unassigned" : split.yoloName.capitalized) { model.setSplit(split, for: selectedImageIDsForContext) }
                }
            }
            Divider()
            Button("Trash \(selectedImageIDsForContext.count == 1 ? "Image" : "Images")", role: .destructive) { model.deleteImages(ids: selectedImageIDsForContext) }
        }
        .accessibilityLabel("\(image.fileName), \(annotationCount) annotations")
    }

    private var annotationCount: Int {
        model.annotationCount(for: image.id)
    }

    private var selectedImageIDsForContext: Set<UUID> {
        model.selectedImageIDs.contains(image.id) ? model.selectedImageIDs : [image.id]
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
