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

    var body: some View {
        let _ = model.browserDataRevision
        let _ = model.selectedImageIDs
        DatasetListTable(model: model)
            .overlay { if model.filteredImages.isEmpty { ContentUnavailableView.search(text: model.searchText) } }
            .navigationTitle(model.dataset?.name ?? "Dataset")
    }
}

private enum ListColumn {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let size = NSUserInterfaceItemIdentifier("size")
    static let split = NSUserInterfaceItemIdentifier("split")
    static let labels = NSUserInterfaceItemIdentifier("labels")
}

/// NSTableView-backed list. SwiftUI's `Table` stalls the main thread for a
/// long time when it diffs a reordered data array of tens of thousands of
/// rows; AppKit's table view reuses cells and reloads in near-constant time,
/// so header sorting stays fluid at any dataset size.
private struct DatasetListTable: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> DatasetListCoordinator {
        DatasetListCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(model: model)
    }
}

@MainActor
private final class DatasetListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum SortKey: Int {
        case name, size, split, labels
    }

    private var model: AppModel
    private var rows: [DatasetListRow] = []
    private var lastRowIDs: [UUID] = []
    private var sortKey: SortKey = .name
    private var sortAscending = true
    private var sortingTask: Task<Void, Never>?
    private var lastRevision = -1
    private var isSyncingSelection = false
    private var lastSelection: Set<UUID> = []
    private var menuTargets: Set<UUID> = []
    private var prefetchScheduled = false
    private weak var tableView: NSTableView?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    deinit {
        sortingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func makeScrollView() -> NSScrollView {
        let table = NSTableView()
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(handleDoubleAction)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 42
        table.usesAutomaticRowHeights = false

        let nameColumn = NSTableColumn(identifier: ListColumn.name)
        nameColumn.title = "Name"
        nameColumn.minWidth = 160
        nameColumn.width = 280
        nameColumn.resizingMask = .autoresizingMask
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "fileName", ascending: true)

        let sizeColumn = NSTableColumn(identifier: ListColumn.size)
        sizeColumn.title = "Size"
        sizeColumn.width = 90
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "pixelArea", ascending: true)

        let splitColumn = NSTableColumn(identifier: ListColumn.split)
        splitColumn.title = "Split"
        splitColumn.width = 90
        splitColumn.sortDescriptorPrototype = NSSortDescriptor(key: "splitRank", ascending: true)

        let labelsColumn = NSTableColumn(identifier: ListColumn.labels)
        labelsColumn.title = "Labels"
        labelsColumn.width = 80
        labelsColumn.sortDescriptorPrototype = NSSortDescriptor(key: "labelCount", ascending: true)

        table.addTableColumn(nameColumn)
        table.addTableColumn(sizeColumn)
        table.addTableColumn(splitColumn)
        table.addTableColumn(labelsColumn)
        table.sortDescriptors = [NSSortDescriptor(key: "fileName", ascending: true)]

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        tableView = table
        return scrollView
    }

    // MARK: - Updates

    func update(model: AppModel) {
        self.model = model
        if model.browserDataRevision != lastRevision {
            lastRevision = model.browserDataRevision
            rebuildRows()
        }
        syncSelectionIfNeeded()
    }

    private func rebuildRows() {
        let base = model.filteredImages.map { DatasetListRow(image: $0, labelCount: model.annotationCount(for: $0.id)) }
        applySort(to: base)
    }

    private func applySort(to base: [DatasetListRow]) {
        let key = sortKey
        let ascending = sortAscending
        sortingTask?.cancel()
        sortingTask = Task { @MainActor [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                Self.sortRows(base, key: key, ascending: ascending)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.presentRows(sorted)
        }
    }

    nonisolated private static func sortRows(_ rows: [DatasetListRow], key: SortKey, ascending: Bool) -> [DatasetListRow] {
        rows.sorted { lhs, rhs in
            let result: ComparisonResult
            switch key {
            case .name:
                result = (lhs.sortNameKey as NSString).compare(rhs.sortNameKey, options: .numeric)
            case .size:
                result = lhs.pixelArea == rhs.pixelArea ? .orderedSame : (lhs.pixelArea < rhs.pixelArea ? .orderedAscending : .orderedDescending)
            case .split:
                result = lhs.splitRank == rhs.splitRank ? .orderedSame : (lhs.splitRank < rhs.splitRank ? .orderedAscending : .orderedDescending)
            case .labels:
                result = lhs.labelCount == rhs.labelCount ? .orderedSame : (lhs.labelCount < rhs.labelCount ? .orderedAscending : .orderedDescending)
            }
            if result == .orderedSame { return lhs.idString < rhs.idString }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func presentRows(_ newRows: [DatasetListRow]) {
        guard !hasSameOrder(newRows) else { return }
        rows = newRows
        lastRowIDs = newRows.map(\.id)
        tableView?.reloadData()
        applySelection(model.selectedImageIDs)
        DispatchQueue.main.async { [weak self] in self?.prefetchVisibleThumbnails() }
    }

    private func hasSameOrder(_ newRows: [DatasetListRow]) -> Bool {
        guard newRows.count == lastRowIDs.count else { return false }
        for index in newRows.indices where newRows[index].id != lastRowIDs[index] { return false }
        return true
    }

    // MARK: - Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        switch descriptor.key {
        case "fileName": sortKey = .name
        case "pixelArea": sortKey = .size
        case "splitRank": sortKey = .split
        case "labelCount": sortKey = .labels
        default: return
        }
        sortAscending = descriptor.ascending
        applySort(to: rows)
    }

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        switch column.identifier {
        case ListColumn.name:
            let cell = tableView.makeView(withIdentifier: ListColumn.name, owner: self) as? ListNameCellView ?? ListNameCellView()
            cell.configure(fileName: item.fileName, url: imageURL(for: item.image))
            return cell
        case ListColumn.size:
            return textCell(tableView, identifier: ListColumn.size, text: "\(item.image.size.width) × \(item.image.size.height)", secondary: true)
        case ListColumn.split:
            return textCell(tableView, identifier: ListColumn.split, text: item.splitTitle, secondary: false)
        case ListColumn.labels:
            return textCell(tableView, identifier: ListColumn.labels, text: item.labelCount.formatted(), secondary: true)
        default:
            return nil
        }
    }

    private func textCell(_ tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier, text: String, secondary: Bool) -> NSTableCellView {
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            let view = NSTableCellView(frame: .zero)
            view.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            view.addSubview(label)
            view.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            cell = view
        }
        if let label = cell.textField {
            label.stringValue = text
            label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
            label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        }
        return cell
    }

    // MARK: - Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let tableView else { return }
        let ids = selectedRowIDs(tableView)
        if ids != model.selectedImageIDs {
            model.selectImages(ids)
        }
    }

    @objc private func handleDoubleAction(_ sender: Any?) {
        guard let tableView else { return }
        let ids = selectedRowIDs(tableView)
        guard !ids.isEmpty else { return }
        model.selectImages(ids)
        model.browserMode = .workspace
    }

    private func selectedRowIDs(_ table: NSTableView) -> Set<UUID> {
        Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
    }

    private func syncSelectionIfNeeded() {
        guard let tableView, !isSyncingSelection else { return }
        let wanted = model.selectedImageIDs
        guard wanted != lastSelection else { return }
        applySelection(wanted)
    }

    private func applySelection(_ wanted: Set<UUID>) {
        guard let tableView, !isSyncingSelection, wanted != lastSelection else { return }
        lastSelection = wanted
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        var indexes = IndexSet()
        for (index, row) in rows.enumerated() where wanted.contains(row.id) { indexes.insert(index) }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    // MARK: - Context menu

    func tableView(_ tableView: NSTableView, menuFor row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let clickedID = rows[row].id
        menuTargets = model.selectedImageIDs.contains(clickedID) ? model.selectedImageIDs : [clickedID]
        return makeContextMenu(for: menuTargets)
    }

    private func makeContextMenu(for ids: Set<UUID>) -> NSMenu {
        let menu = NSMenu()

        if let firstID = ids.first,
           let image = model.dataset?.images.first(where: { $0.id == firstID }),
           let url = imageURL(for: image) {
            let item = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }

        let splitItem = menu.addItem(withTitle: "Set Split", action: nil, keyEquivalent: "")
        let splitMenu = NSMenu()
        for split in [DatasetSplit.train, .validation, .test, .unassigned] {
            let item = splitMenu.addItem(withTitle: split == .unassigned ? "Unassigned" : split.yoloName.capitalized, action: #selector(setSplit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = split.rawValue
        }
        menu.setSubmenu(splitMenu, for: splitItem)

        let tagsItem = menu.addItem(withTitle: "Tags", action: nil, keyEquivalent: "")
        let tagsMenu = NSMenu()
        if let dataset = model.dataset, !dataset.tags.isEmpty {
            for tag in dataset.tags {
                let item = tagsMenu.addItem(withTitle: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tag.id
                item.state = isFullyApplied(tag.id, to: ids) ? .on : .off
            }
            tagsMenu.addItem(.separator())
        }
        let newTag = tagsMenu.addItem(withTitle: "New Tag…", action: #selector(createTag(_:)), keyEquivalent: "")
        newTag.target = self
        menu.setSubmenu(tagsMenu, for: tagsItem)

        menu.addItem(.separator())
        let trash = menu.addItem(withTitle: ids.count == 1 ? "Trash Image" : "Trash \(ids.count) Images", action: #selector(trashSelected(_:)), keyEquivalent: "")
        trash.target = self
        return menu
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func setSplit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let split = DatasetSplit(rawValue: raw), !menuTargets.isEmpty else { return }
        model.setSplit(split, for: menuTargets)
    }

    @objc private func toggleTag(_ sender: NSMenuItem) {
        guard let tagID = sender.representedObject as? UUID, !menuTargets.isEmpty else { return }
        model.setTag(tagID, enabled: sender.state != .on, for: menuTargets)
    }

    @objc private func trashSelected(_ sender: NSMenuItem) {
        guard !menuTargets.isEmpty else { return }
        model.deleteImages(ids: menuTargets)
    }

    @objc private func createTag(_ sender: NSMenuItem) {
        guard !menuTargets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = "Name the tag to apply to the selected images."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Tag name"
        field.stringValue = "New Tag"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { model.addTag(name: name, to: menuTargets) }
        }
    }

    private func isFullyApplied(_ tagID: UUID, to ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty, let dataset = model.dataset else { return false }
        let imagesByID = Dictionary(uniqueKeysWithValues: dataset.images.map { ($0.id, $0) })
        return ids.allSatisfy { imagesByID[$0]?.tagIDs.contains(tagID) == true }
    }

    // MARK: - Thumbnail prefetch

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        guard !prefetchScheduled else { return }
        prefetchScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.prefetchScheduled = false
            self?.prefetchVisibleThumbnails()
        }
    }

    private func prefetchVisibleThumbnails() {
        guard let tableView else { return }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        let urls = (range.location..<(range.location + range.length)).compactMap { index in
            rows.indices.contains(index) ? imageURL(for: rows[index].image) : nil
        }
        guard !urls.isEmpty else { return }
        Task { await ImageLoader.shared.prefetch(urls, maximumPixelSize: 64) }
    }

    private func imageURL(for image: DatasetImage) -> URL? {
        model.imageURL(for: image)
    }
}

@MainActor
private final class ListNameCellView: NSTableCellView {
    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var thumbnailURL: URL?
    private var thumbnailToken = UUID()

    init() {
        super.init(frame: .zero)
        identifier = ListColumn.name
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        addSubview(thumbnailView)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 52),
            thumbnailView.heightAnchor.constraint(equalToConstant: 38),
            nameLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("ListNameCellView does not support coder-based initialization") }

    func configure(fileName: String, url: URL?) {
        nameLabel.stringValue = fileName
        guard url != thumbnailURL else { return }
        thumbnailURL = url
        thumbnailToken = UUID()
        thumbnailView.image = nil
        guard let url else { return }
        let token = thumbnailToken
        Task { @MainActor in
            let image = await ThumbnailStore.shared.image(at: url, maxPixelSize: 64)
            guard self.thumbnailToken == token else { return }
            self.thumbnailView.image = image
        }
    }
}

private struct DatasetListRow: Identifiable, Sendable {
    let image: DatasetImage
    let idString: String
    let fileName: String
    let sortNameKey: String
    let pixelArea: Int64
    let splitRank: Int
    let splitTitle: String
    let labelCount: Int

    var id: UUID { image.id }
    init(image: DatasetImage, labelCount: Int) {
        self.image = image
        self.idString = image.id.uuidString
        self.fileName = image.fileName
        self.sortNameKey = AppModel.foldedSortKey(image.fileName)
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

    private struct Entry {
        let image: NSImage
        let cost: Int
    }

    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private var totalCost = 0
    private let costLimit = 128 * 1_024 * 1_024

    func image(at url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = Self.cacheKey(url: url, maximumPixelSize: maxPixelSize)
        if let entry = cache[key] {
            touch(key)
            return entry.image
        }
        guard let cgImage = try? await ImageLoader.shared.thumbnail(at: url, maximumPixelSize: maxPixelSize) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let cost = max(cgImage.bytesPerRow * cgImage.height, 1)
        insert(key: key, image: nsImage, cost: cost)
        return nsImage
    }

    func removeAll() {
        cache.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func insert(key: String, image: NSImage, cost: Int) {
        cache[key] = Entry(image: image, cost: cost)
        totalCost += cost
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
        while totalCost > costLimit, let oldest = order.first {
            order.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { totalCost -= removed.cost }
        }
    }

    private static func cacheKey(url: URL, maximumPixelSize: Int) -> String {
        "\(url.standardizedFileURL.path)#\(maximumPixelSize)"
    }
}
