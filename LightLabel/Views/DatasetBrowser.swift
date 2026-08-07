import AppKit
import ImageIO
import SwiftUI

struct DatasetGrid: View {
    @Bindable var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)]
    @State private var imageIDs: [UUID] = []
    @State private var sortTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(imageIDs, id: \.self) { id in
                    if let image = model.image(for: id) {
                        ImageCard(model: model, image: image)
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if model.filteredImageCount == 0 { ContentUnavailableView.search(text: model.searchText) } }
        .navigationTitle(model.dataset?.name ?? "Dataset")
        .task(id: gridTaskID) {
            rebuildImageOrder()
        }
        .onDisappear {
            sortTask?.cancel()
        }
    }

    private var gridTaskID: String {
        "(model.browserDataRevision)-(model.imageSortKey.rawValue)-(model.imageSortAscending)"
    }

    private func rebuildImageOrder() {
        sortTask?.cancel()
        let snapshots = model.filteredImageSnapshots()
        let descriptor = ImageSortDescriptor(key: model.imageSortKey, ascending: model.imageSortAscending)
        let worker = Task.detached(priority: .userInitiated) {
            try await cancellableMergeSort(snapshots, by: descriptor.compare)
        }
        sortTask = Task { @MainActor in
            do {
                let sorted = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                imageIDs = sorted.map(\.id)
            } catch {
                // A superseded sort is expected during rapid filtering/sorting.
            }
        }
    }
}

struct DatasetList: View {
    @Bindable var model: AppModel
    @State private var sortOrder = [KeyPathComparator<DatasetListRow>(\.fileName)]
    @State private var tableRows: [DatasetListRow] = []
    @State private var sortingTask: Task<Void, Never>?

    var body: some View {
        Table(tableRows, selection: Binding<Set<UUID>>(get: { model.selectedImageIDs }, set: { ids in model.selectImages(ids) }), sortOrder: tableSortOrder) {
            TableColumn("Name", value: \.fileName) { row in
                HStack(spacing: 10) {
                    ThumbnailView(url: model.imageURL(forRelativePath: row.relativePath), maxPixelSize: 64)
                        .frame(width: 52, height: 38).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(row.fileName).lineLimit(1)
                }
            }
            TableColumn("Size", value: \.pixelArea) { row in
                Text("\(row.width) × \(row.height)")
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
                if let id = ids.first, let image = model.image(for: id), let url = model.imageURL(for: image) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Menu("Set Split") {
                    ForEach([DatasetSplit.train, .validation, .test, .unassigned], id: \.self) { split in
                        Button(split == .unassigned ? "Unassigned" : split.yoloName.capitalized) { model.setSplit(split, for: ids) }
                    }
                }
                ImageTagMenu(model: model, imageIDs: ids)
                Divider()
                Button("Trash \(ids.count == 1 ? "Image" : "Images")", role: .destructive) { model.deleteImages(ids: ids) }
            }
        } primaryAction: { ids in
            model.selectImages(ids)
            model.browserMode = .workspace
        }
        .overlay { if model.filteredImageCount == 0 { ContentUnavailableView.search(text: model.searchText) } }
        .navigationTitle(model.dataset?.name ?? "Dataset")
        .task(id: model.browserDataRevision) {
            rebuildTableRows()
        }
        .onDisappear {
            sortingTask?.cancel()
        }
    }

    private var tableSortOrder: Binding<[KeyPathComparator<DatasetListRow>]> {
        Binding(
            get: { sortOrder },
            set: { newOrder in
                sortOrder = newOrder
                scheduleSort(Self.sortDescriptor(for: newOrder))
            }
        )
    }

    private func rebuildTableRows() {
        let rows = model.filteredImageSnapshots().map { DatasetListRow(snapshot: $0, labelCount: model.annotationCount(for: $0.id)) }
        scheduleSort(Self.sortDescriptor(for: sortOrder), rows: rows)
    }

    private func scheduleSort(_ descriptor: DatasetListSortDescriptor, rows: [DatasetListRow]? = nil) {
        sortingTask?.cancel()
        let input = rows ?? tableRows
        sortingTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                try await input.sorted(using: descriptor)
            }
            do {
                let sorted = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                tableRows = sorted
            } catch is CancellationError {
                // A newer filter or sort request superseded this work.
            } catch {
                // Sorting is an in-memory operation; a failed/cancelled sort
                // should never take down the browser.
            }
        }
    }

    private static func sortDescriptor(for order: [KeyPathComparator<DatasetListRow>]) -> DatasetListSortDescriptor {
        guard let comparator = order.first else { return .init(key: .name, ascending: true) }
        let key: DatasetListSortDescriptor.Key
        if comparator.keyPath == \.fileName {
            key = .name
        } else if comparator.keyPath == \.pixelArea {
            key = .size
        } else if comparator.keyPath == \.splitRank {
            key = .split
        } else {
            key = .labels
        }
        return .init(key: key, ascending: comparator.order == .forward)
    }
}

private struct DatasetListSortDescriptor: Sendable, Equatable {
    enum Key: Sendable {
        case name
        case size
        case split
        case labels
    }

    let key: Key
    let ascending: Bool

    func compare(_ lhs: DatasetListRow, _ rhs: DatasetListRow) -> Bool {
        let result: ComparisonResult
        switch key {
        case .name:
            result = lhs.fileName.localizedStandardCompare(rhs.fileName)
        case .size:
            result = lhs.pixelArea == rhs.pixelArea ? .orderedSame : (lhs.pixelArea < rhs.pixelArea ? .orderedAscending : .orderedDescending)
        case .split:
            result = lhs.splitRank == rhs.splitRank ? .orderedSame : (lhs.splitRank < rhs.splitRank ? .orderedAscending : .orderedDescending)
        case .labels:
            result = lhs.labelCount == rhs.labelCount ? .orderedSame : (lhs.labelCount < rhs.labelCount ? .orderedAscending : .orderedDescending)
        }
        if result == .orderedSame { return lhs.sourceIndex < rhs.sourceIndex }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }
}

private extension Array where Element == DatasetListRow {
    func sorted(using descriptor: DatasetListSortDescriptor) async throws -> [DatasetListRow] {
        try await cancellableMergeSort(self, by: descriptor.compare)
    }
}

private struct DatasetListRow: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let relativePath: String
    let width: Int
    let height: Int
    let pixelArea: Int64
    let splitRank: Int
    let splitTitle: String
    let labelCount: Int
    let sourceIndex: Int

    init(snapshot: ImageBrowserSnapshot, labelCount: Int) {
        self.id = snapshot.id
        self.fileName = snapshot.fileName
        self.relativePath = snapshot.relativePath
        self.width = snapshot.width
        self.height = snapshot.height
        self.pixelArea = snapshot.pixelArea
        self.splitRank = Self.rank(for: snapshot.split)
        self.splitTitle = snapshot.split == .unassigned ? "Unassigned" : snapshot.split.yoloName.capitalized
        self.labelCount = labelCount
        self.sourceIndex = snapshot.sourceIndex
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
                    ThumbnailView(url: model.imageURL(for: image), maxPixelSize: 384)
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
            ImageTagMenu(model: model, imageIDs: selectedImageIDsForContext)
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

struct ImageTagMenu: View {
    let model: AppModel
    let imageIDs: Set<UUID>
    @State private var editor: TagEditor?

    var body: some View {
        Menu("Tags", systemImage: "tag") {
            if let tags = model.dataset?.tags, !tags.isEmpty {
                ForEach(tags) { tag in
                    Button {
                        model.setTag(tag.id, enabled: !isFullyApplied(tag.id), for: imageIDs)
                    } label: {
                        Label(tag.name, systemImage: isFullyApplied(tag.id) ? "checkmark" : "tag")
                    }
                }
                Divider()
            }
            Button("New Tag…") {
                editor = .init(tagID: nil, name: "New Tag", color: .gray)
            }
        }
        .sheet(item: $editor) { editor in
            TagEditorSheet(editor: editor) { name, color in
                model.addTag(name: name, colorHex: color.hexString, to: imageIDs)
            }
        }
    }

    private func isFullyApplied(_ tagID: UUID) -> Bool {
        guard !imageIDs.isEmpty, let dataset = model.dataset else { return false }
        return imageIDs.allSatisfy { imageID in
            dataset.images.first(where: { $0.id == imageID })?.tagIDs.contains(tagID) == true
        }
    }
}

struct ImageTagChips: View {
    let model: AppModel
    let image: DatasetImage

    var body: some View {
        let tags = model.dataset?.tags.filter { image.tagIDs.contains($0.id) } ?? []
        if tags.isEmpty {
            Text("No tags")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: tag.colorHex)).frame(width: 7, height: 7)
                            Text(tag.name).lineLimit(1)
                            Button {
                                model.setTag(tag.id, enabled: false, for: [image.id])
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag.name)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color(hex: tag.colorHex).opacity(0.14), in: Capsule())
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
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
