import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import CoreML
import ImageIO

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select = "Select"
    case box = "Box"
    case polygon = "Polygon"
    case smartPolygon = "Smart Polygon"
    case pan = "Pan"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .select: "arrow.up.left"
        case .box: "rectangle.dashed"
        case .polygon: "point.3.connected.trianglepath.dotted"
        case .smartPolygon: "wand.and.stars"
        case .pan: "hand.draw"
        }
    }
}

enum BrowserMode: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case grid = "Grid"
    case list = "List"

    var id: Self { self }
}

enum SplitFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case train = "Train"
    case validation = "Validation"
    case test = "Test"

    var id: Self { self }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All images"
    case unannotated = "Unannotated"
    case annotated = "Annotated"
    case suggestions = "AI suggestions"

    var id: Self { self }
}

enum ImageSortKey: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case split = "Split"
    case labels = "Labels"

    var id: Self { self }
}

struct CanvasViewport: Equatable {
    var zoom = 1.0
    var pan = CGSize.zero
    var fitRequest = 0
}

struct ValidationSummary: Equatable {
    var errors = 0
    var warnings = 0
    var message = "Validation has not been run"
}

struct OperationProgress: Equatable {
    var title: String
    var completed: Double
    var isCancellable: Bool
}

protocol DatasetApplicationServices: Sendable {
    func openDataset(at url: URL) async throws -> AnnotationDataset
    func createDataset(named name: String, at url: URL, syncFormat: DatasetSyncFormat) async throws -> AnnotationDataset
    func addImages(_ urls: [URL], to dataset: AnnotationDataset) async throws -> AnnotationDataset
    func save(_ dataset: AnnotationDataset) async throws
    func importDataset(from url: URL) async throws -> AnnotationDataset
    func mergeDataset(from url: URL, into dataset: AnnotationDataset) async throws -> AnnotationDataset
    func export(_ dataset: AnnotationDataset, to url: URL) async throws
    func validate(_ dataset: AnnotationDataset) async throws -> ValidationSummary
    func runInference(for image: DatasetImage, in dataset: AnnotationDataset) async throws -> [DatasetAnnotation]
    func loadModel(from url: URL) async throws
    func smartSplit(_ dataset: AnnotationDataset, trainRatio: Double, validationRatio: Double) async throws -> AnnotationDataset
}

extension DatasetApplicationServices {
    func mergeDataset(from url: URL, into dataset: AnnotationDataset) async throws -> AnnotationDataset {
        throw DatasetFormatError.unsupported("Merging datasets is not available for this dataset service")
    }

    func smartSplit(_ dataset: AnnotationDataset, trainRatio: Double, validationRatio: Double) async throws -> AnnotationDataset {
        var copy = dataset
        let assignments = SmartSplitPlanner().assignments(images: dataset.images, annotations: dataset.annotations, configuration: .init(trainRatio: trainRatio, validationRatio: validationRatio))
        for index in copy.images.indices where assignments[copy.images[index].id] != nil {
            copy.images[index].split = assignments[copy.images[index].id] ?? .unassigned
        }
        return copy
    }
}

private enum DatasetSyncMetadata {
    static let format = "lightlabel.sync.format"
    static let source = "lightlabel.sync.source"
    static let task = "lightlabel.sync.task"
    static let yolo = "yolo"
    static let coco = "coco"
}

struct LocalDatasetServices: DatasetApplicationServices {
    private let inferenceStore = LocalInferenceStore()

    func openDataset(at url: URL) async throws -> AnnotationDataset {
        let persistence = ProjectPersistence(directoryURL: url.appendingPathComponent(".lightlabel"))
        if let saved = try? await persistence.loadDataset() {
            let hasExternalFormat = FileManager.default.fileExists(atPath: url.appendingPathComponent("data.yaml").path)
                || FileManager.default.fileExists(atPath: url.appendingPathComponent("dataset.yaml").path)
                || !Self.cocoJSONFiles(in: url).isEmpty
            let hasMissingImages = saved.images.isEmpty && hasExternalFormat
                || saved.images.contains { !FileManager.default.fileExists(atPath: Self.resolvedImageURL($0, root: url).path) }
            if !hasMissingImages { return saved.withRootURL(url) }
        }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("data.yaml").path) {
            return try YOLOImporter().importDataset(at: url).dataset
                .withRootURL(url)
                .withSyncMetadata(format: DatasetSyncMetadata.yolo, source: url.path)
        }
        let candidates = Self.cocoJSONFiles(in: url)
        guard let first = candidates.first else { throw DatasetFormatError.unreadableFile("data.yaml or COCO JSON") }
        var imported = try COCOImporter().importDataset(at: first, imageRoot: url).dataset
        for json in candidates.dropFirst() {
            let next = try COCOImporter().importDataset(at: json, imageRoot: url).dataset
            imported = Self.combined(imported, with: next, name: url.lastPathComponent)
        }
        let source = candidates.count == 1 ? first.path : url.appendingPathComponent("annotations.json").path
        return imported
            .withRootURL(url)
            .withSyncMetadata(format: DatasetSyncMetadata.coco, source: source)
    }

    func createDataset(named name: String, at url: URL, syncFormat: DatasetSyncFormat) async throws -> AnnotationDataset {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dataset = AnnotationDataset(name: name)
            .withRootURL(url)
            .withSyncMetadata(format: syncFormat.storageFormat, source: syncFormat == .coco ? url.appendingPathComponent("annotations.json").path : url.path, task: syncFormat.yoloTask)
        if syncFormat != .coco {
            for split in [DatasetSplit.train, .validation, .test] {
                try FileManager.default.createDirectory(at: url.appendingPathComponent("images/\(split.yoloName)"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: url.appendingPathComponent("labels/\(split.yoloName)"), withIntermediateDirectories: true)
            }
        } else {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("images"), withIntermediateDirectories: true)
        }
        try await ProjectPersistence(directoryURL: url.appendingPathComponent(".lightlabel")).save(dataset)
        try synchronizeExternalDataset(dataset)
        return dataset
    }

    func addImages(_ urls: [URL], to dataset: AnnotationDataset) async throws -> AnnotationDataset {
        guard let root = dataset.rootURL else { throw DatasetFormatError.invalidData("Dataset has no root folder") }
        let isYOLO = dataset.metadata[DatasetSyncMetadata.format] == DatasetSyncMetadata.yolo
        let directory = root.appendingPathComponent(isYOLO ? "images/train" : "images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var updated = dataset
        for source in urls {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
            guard let size = Self.imageSize(at: destination) else { continue }
            let relativePath = isYOLO ? "images/train/\(destination.lastPathComponent)" : "images/\(destination.lastPathComponent)"
            guard !updated.images.contains(where: { $0.relativePath == relativePath }) else { continue }
            updated.images.append(.init(fileName: destination.lastPathComponent, relativePath: relativePath, size: size))
        }
        return updated
    }

    func save(_ dataset: AnnotationDataset) async throws {
        guard let root = dataset.rootURL else { throw DatasetFormatError.invalidData("Dataset has no root folder") }
        try await ProjectPersistence(directoryURL: root.appendingPathComponent(".lightlabel")).save(dataset)
        try synchronizeExternalDataset(dataset)
    }

    func importDataset(from url: URL) async throws -> AnnotationDataset {
        if Self.isDirectory(url) {
            return try await openDataset(at: url)
        }
        if url.pathExtension.lowercased() == "json" {
            let (imported, imageRoot) = try Self.importCOCOFile(at: url)
            return imported
                .withRootURL(imageRoot)
                .withSyncMetadata(format: DatasetSyncMetadata.coco, source: url.path)
        }
        if ["yaml", "yml"].contains(url.pathExtension.lowercased()) {
            let root = url.deletingLastPathComponent()
            return try YOLOImporter().importDataset(at: root).dataset
                .withRootURL(root)
                .withSyncMetadata(format: DatasetSyncMetadata.yolo, source: root.path)
        }
        throw DatasetFormatError.unsupported("Choose a dataset folder, data.yaml, or COCO JSON file")
    }

    func mergeDataset(from url: URL, into dataset: AnnotationDataset) async throws -> AnnotationDataset {
        guard let targetRoot = dataset.rootURL else { throw DatasetFormatError.invalidData("Dataset has no root folder") }
        let imported = try await importDataset(from: url)
        guard let sourceRoot = imported.rootURL else { throw DatasetFormatError.invalidData("Imported dataset has no root folder") }
        guard !imported.images.isEmpty else {
            throw DatasetFormatError.invalidData("The imported dataset contains no readable images. Check its image folders and data.yaml paths.")
        }

        let targetIsYOLO = dataset.metadata[DatasetSyncMetadata.format] == DatasetSyncMetadata.yolo
        let sourceImages = imported.images.map { image in
            (image: image, url: Self.resolvedImageURL(image, root: sourceRoot))
        }
        let missingImages = sourceImages.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        guard missingImages.isEmpty else {
            let examples = missingImages.prefix(3).map { $0.image.fileName }.joined(separator: ", ")
            throw DatasetFormatError.invalidData("Could not find \(missingImages.count) source image file(s): \(examples)")
        }

        var result = dataset
        var categoryMap: [UUID: UUID] = [:]
        for category in imported.categories {
            if let existing = result.categories.first(where: { $0.name.caseInsensitiveCompare(category.name) == .orderedSame }) {
                categoryMap[category.id] = existing.id
            } else {
                var copy = category
                copy.id = UUID()
                copy.sourceID = nil
                result.categories.append(copy)
                categoryMap[category.id] = copy.id
            }
        }

        var imageMap: [UUID: UUID] = [:]
        for (image, sourceURL) in sourceImages {
            let split = image.split == .unassigned ? DatasetSplit.train : image.split
            let directory = targetIsYOLO ? "images/\(split.yoloName)" : "images/imported"
            try FileManager.default.createDirectory(at: targetRoot.appendingPathComponent(directory), withIntermediateDirectories: true)
            var relativePath = "\(directory)/\(image.fileName)"
            var destination = targetRoot.appendingPathComponent(relativePath)
            if result.images.contains(where: { $0.relativePath == relativePath }) || FileManager.default.fileExists(atPath: destination.path) {
                let stem = destination.deletingPathExtension().lastPathComponent
                let ext = destination.pathExtension
                relativePath = "\(directory)/\(stem)-\(UUID().uuidString.prefix(8)).\(ext)"
                destination = targetRoot.appendingPathComponent(relativePath)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            var copy = image
            copy.id = UUID()
            copy.relativePath = relativePath
            copy.fileName = destination.lastPathComponent
            if targetIsYOLO, copy.split == .unassigned { copy.split = .train }
            copy.sourceID = nil
            result.images.append(copy)
            imageMap[image.id] = copy.id
        }

        for annotation in imported.annotations {
            guard let imageID = imageMap[annotation.imageID], let categoryID = categoryMap[annotation.categoryID] else { continue }
            var copy = annotation
            copy.id = UUID()
            copy.imageID = imageID
            copy.categoryID = categoryID
            copy.sourceID = nil
            result.annotations.append(copy)
        }
        return result
    }

    func export(_ dataset: AnnotationDataset, to url: URL) async throws {
        switch await ExportChoiceDialog.present() {
        case .yoloDetection: _ = try YOLOExporter().export(dataset, to: url, task: .detection)
        case .yoloSegmentation: _ = try YOLOExporter().export(dataset, to: url, task: .segmentation)
        case .coco: _ = try COCOExporter().export(dataset, to: url.appendingPathComponent("annotations.json"))
        case .cancel: throw CancellationError()
        }
    }

    private func synchronizeExternalDataset(_ dataset: AnnotationDataset) throws {
        guard let format = dataset.metadata[DatasetSyncMetadata.format],
              let source = dataset.metadata[DatasetSyncMetadata.source] else { return }
        let sourceURL = URL(fileURLWithPath: source)
        switch format {
        case DatasetSyncMetadata.yolo:
            let task = dataset.metadata[DatasetSyncMetadata.task].flatMap(YOLOTask.init(rawValue:)) ?? .automatic
            _ = try YOLOExporter().export(dataset, to: sourceURL, task: task)
        case DatasetSyncMetadata.coco:
            _ = try COCOExporter().export(dataset, to: sourceURL)
        default:
            break
        }
    }

    func smartSplit(_ dataset: AnnotationDataset, trainRatio: Double, validationRatio: Double) async throws -> AnnotationDataset {
        var signatures: [UUID: UInt64] = [:]
        if let root = dataset.rootURL {
            // ImageLoader already bounds actual decodes. Batching the task
            // group as well avoids creating one waiting task per image for
            // very large datasets.
            let batchSize = 64
            for start in stride(from: 0, to: dataset.images.count, by: batchSize) {
                let end = min(start + batchSize, dataset.images.count)
                let batch = Array(dataset.images[start..<end])
                await withTaskGroup(of: (UUID, UInt64)?.self) { group in
                    for image in batch {
                        let url = root.appendingPathComponent(image.relativePath)
                        group.addTask {
                            guard FileManager.default.fileExists(atPath: url.path),
                                  let thumbnail = try? await ImageLoader.shared.thumbnail(at: url, maximumPixelSize: 64, appliesOrientation: false),
                                  let signature = SmartSplitPlanner.perceptualSignature(thumbnail) else { return nil }
                            return (image.id, signature)
                        }
                    }
                    for await result in group {
                        if let result { signatures[result.0] = result.1 }
                    }
                }
            }
        }
        let configuration = SmartSplitConfiguration(trainRatio: trainRatio, validationRatio: validationRatio)
        let assignments = SmartSplitPlanner().assignments(images: dataset.images, annotations: dataset.annotations, signatures: signatures, configuration: configuration)
        var result = dataset
        for index in result.images.indices where assignments[result.images[index].id] != nil {
            result.images[index].split = assignments[result.images[index].id] ?? .unassigned
        }
        return result
    }

    func validate(_ dataset: AnnotationDataset) async throws -> ValidationSummary {
        let issues = DatasetValidator().validate(dataset)
        return .init(errors: issues.count { $0.severity == .error }, warnings: issues.count { $0.severity == .warning }, message: issues.isEmpty ? "Dataset is valid" : "\(issues.count) issues found")
    }

    func runInference(for image: DatasetImage, in dataset: AnnotationDataset) async throws -> [DatasetAnnotation] {
        guard let root = dataset.rootURL else { throw DatasetFormatError.invalidData("Dataset has no root folder") }
        let cgImage = try await ImageLoader(maximumConcurrentLoads: 1).fullImage(at: root.appendingPathComponent(image.relativePath))
        let detections = try await inferenceStore.infer(cgImage)
        return detections.compactMap { detection in
            let categoryIndex = dataset.categories.indices.contains(detection.categoryIndex) ? detection.categoryIndex : dataset.categories.firstIndex { $0.name == detection.label }
            guard let categoryIndex else { return nil }
            return .init(imageID: image.id, categoryID: dataset.categories[categoryIndex].id, geometry: .boundingBox(detection.boundingBox), attributes: .init(confidence: detection.confidence), source: .aiSuggestion)
        }
    }

    func loadModel(from url: URL) async throws { try await inferenceStore.load(url) }

    private static func imageSize(at url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return .init(width: width, height: height)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func cocoJSONFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "json",
                  !url.path.contains("/.lightlabel/") else { return nil }
            return url
        }.filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            guard let probe = try? JSONDecoder().decode(COCOProbe.self, from: data) else { return false }
            return probe.images != nil && probe.annotations != nil && probe.categories != nil
        }.sorted { $0.path < $1.path }
    }

    private static func importCOCOFile(at url: URL) throws -> (dataset: AnnotationDataset, imageRoot: URL) {
        let parent = url.deletingLastPathComponent()
        var candidates: [URL] = []
        var current = parent
        for _ in 0..<8 {
            candidates.append(current)
            let next = current.deletingLastPathComponent()
            if next.path == current.path { break }
            current = next
        }

        var best: (dataset: AnnotationDataset, root: URL, resolvedImages: Int)?
        for root in candidates {
            guard let imported = try? COCOImporter().importDataset(at: url, imageRoot: root).dataset else { continue }
            let resolvedImages = imported.images.count { image in
                FileManager.default.fileExists(atPath: resolvedImageURL(image, root: root).path)
            }
            if best == nil || resolvedImages > best!.resolvedImages {
                best = (imported, root, resolvedImages)
            }
            if resolvedImages == imported.images.count, !imported.images.isEmpty { break }
        }

        if let best { return (best.dataset, best.root) }
        return (try COCOImporter().importDataset(at: url, imageRoot: parent).dataset, parent)
    }

    private static func combined(_ first: AnnotationDataset, with second: AnnotationDataset, name: String) -> AnnotationDataset {
        var result = first
        var categoryMap: [UUID: UUID] = [:]
        for category in second.categories {
            if let existing = result.categories.first(where: { $0.name.caseInsensitiveCompare(category.name) == .orderedSame }) {
                categoryMap[category.id] = existing.id
            } else {
                var copy = category
                copy.id = UUID()
                result.categories.append(copy)
                categoryMap[category.id] = copy.id
            }
        }
        var imageMap: [UUID: UUID] = [:]
        for image in second.images {
            if let existing = result.images.first(where: { $0.relativePath == image.relativePath }) {
                imageMap[image.id] = existing.id
                continue
            }
            var copy = image
            copy.id = UUID()
            result.images.append(copy)
            imageMap[image.id] = copy.id
        }
        for annotation in second.annotations {
            guard let imageID = imageMap[annotation.imageID], let categoryID = categoryMap[annotation.categoryID] else { continue }
            var copy = annotation
            copy.id = UUID()
            copy.imageID = imageID
            copy.categoryID = categoryID
            result.annotations.append(copy)
        }
        result.name = name
        return result
    }

    private static func resolvedImageURL(_ image: DatasetImage, root: URL) -> URL {
        let path = image.relativePath.hasPrefix("/") ? URL(fileURLWithPath: image.relativePath) : root.appendingPathComponent(image.relativePath)
        if FileManager.default.fileExists(atPath: path.path) { return path }
        let fallback = root.appendingPathComponent(image.fileName)
        if FileManager.default.fileExists(atPath: fallback.path) { return fallback }
        if let match = Self.imageFiles(in: root).first(where: { $0.lastPathComponent.caseInsensitiveCompare(image.fileName) == .orderedSame }) {
            return match
        }
        return path
    }

    private static func imageFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item in
            guard let file = item as? URL,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "webp"].contains(file.pathExtension.lowercased()) else { return nil }
            return file
        }
    }

    private struct COCOProbe: Decodable {
        let images: [ProbeImage]?
        let annotations: [ProbeAnnotation]?
        let categories: [ProbeCategory]?
        struct ProbeImage: Decodable { let id: Int?; let fileName: String?
            enum CodingKeys: String, CodingKey { case id, fileName = "file_name" }
        }
        struct ProbeAnnotation: Decodable { let id: Int?
            enum CodingKeys: String, CodingKey { case id }
        }
        struct ProbeCategory: Decodable { let id: Int? }
    }
}

actor LocalInferenceStore {
    private var engine: (any ImageInferenceEngine)?
    func load(_ url: URL) throws {
        let fileExtension = url.pathExtension.lowercased()
        guard ["mlmodel", "mlpackage", "mlmodelc"].contains(fileExtension) else {
            throw InferenceError.modelLoading("Choose an .mlmodel, .mlpackage, or .mlmodelc file")
        }
        do {
            let modelURL = fileExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            engine = try VisionCoreMLInferenceEngine(model: model)
        } catch let error as InferenceError {
            throw error
        } catch {
            throw InferenceError.modelLoading("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
    func infer(_ image: CGImage) async throws -> [InferenceDetection] {
        guard let engine else { throw InferenceError.modelLoading("Load a Core ML model first") }
        return try await engine.infer(image: image)
    }
}

enum ExportChoice: Sendable { case yoloDetection, yoloSegmentation, coco, cancel }

enum ExportChoiceDialog {
    @MainActor static func present() -> ExportChoice {
        let alert = NSAlert()
        alert.messageText = "Export Dataset"
        alert.informativeText = "Choose an annotation format. COCO JSON preserves both boxes and polygons."
        alert.addButton(withTitle: "YOLO Detection")
        alert.addButton(withTitle: "YOLO Segmentation")
        alert.addButton(withTitle: "COCO JSON")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .yoloDetection
        case .alertSecondButtonReturn: return .yoloSegmentation
        case .alertThirdButtonReturn: return .coco
        default: return .cancel
        }
    }
}

private final class DatasetFormatAccessoryView: NSView {
    private let formatPicker = NSPopUpButton()

    var selectedFormat: DatasetSyncFormat {
        switch formatPicker.indexOfSelectedItem {
        case 1: .yoloSegmentation
        case 2: .coco
        default: .yoloDetection
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "Auto-sync format:")
        formatPicker.addItems(withTitles: DatasetSyncFormat.allCases.map(\.title))
        formatPicker.selectItem(at: 0)

        let stack = NSStackView(views: [label, formatPicker])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.widthAnchor.constraint(equalToConstant: 125)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension AnnotationDataset {
    func withRootURL(_ url: URL) -> Self {
        var copy = self
        copy.metadata["lightlabel.rootURL"] = url.standardizedFileURL.path
        return copy
    }

    func withSyncMetadata(format: String, source: String, task: YOLOTask? = nil) -> Self {
        var copy = self
        copy.metadata[DatasetSyncMetadata.format] = format
        copy.metadata[DatasetSyncMetadata.source] = source
        if let task { copy.metadata[DatasetSyncMetadata.task] = task.rawValue }
        return copy
    }
    var rootURL: URL? {
        guard let path = metadata["lightlabel.rootURL"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

@MainActor
@Observable
final class AppModel {
    var dataset: AnnotationDataset? {
        didSet { rebuildIndexes(); invalidateFilteredImages() }
    }
    var selectedImageID: UUID?
    var selectedImageIDs: Set<UUID> = []
    var selectedAnnotationID: UUID?
    var selectedCategoryID: UUID?
    var tool = AnnotationTool.select
    var browserMode = BrowserMode.workspace
    var splitFilter = SplitFilter.all { didSet { invalidateFilteredImages() } }
    var statusFilter = StatusFilter.all { didSet { invalidateFilteredImages() } }
    var searchText = "" { didSet { invalidateFilteredImages() } }
    var imageSortKey = ImageSortKey.name
    var imageSortAscending = true
    // Visible revision used by list/grid views to refresh cached row models
    // only when dataset contents or filters actually changed.
    private(set) var browserDataRevision = 0
    var includedCategoryIDs: Set<UUID> = [] { didSet { invalidateFilteredImages() } }
    var excludedCategoryIDs: Set<UUID> = [] { didSet { invalidateFilteredImages() } }
    var viewport = CanvasViewport()
    var inspectorVisible = true
    var sidebarVisible = true
    var showLabels = true
    var showHandles = true
    var isDirty = false
    var alertMessage: String?
    var validation = ValidationSummary()
    var operation: OperationProgress?

    @ObservationIgnored private let services: any DatasetApplicationServices
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var imagesByID: [UUID: DatasetImage] = [:]
    @ObservationIgnored private var annotationsByID: [UUID: DatasetAnnotation] = [:]
    @ObservationIgnored private var annotationsByImageID: [UUID: [DatasetAnnotation]] = [:]
    @ObservationIgnored private var annotationCountsByCategoryID: [UUID: Int] = [:]
    @ObservationIgnored private var categoryNamesByID: [UUID: String] = [:]
    @ObservationIgnored private var filterRevision = 0
    @ObservationIgnored private var cachedFilterRevision = -1
    @ObservationIgnored private var cachedFilteredImages: [DatasetImage] = []
    @ObservationIgnored private var cachedBrowserRevision = -1
    @ObservationIgnored private var cachedBrowserSortKey = ImageSortKey.name
    @ObservationIgnored private var cachedBrowserSortAscending = true
    @ObservationIgnored private var cachedBrowserImages: [DatasetImage] = []
    @ObservationIgnored private var selectionAnchorImageID: UUID?

    init(services: any DatasetApplicationServices = LocalDatasetServices()) {
        self.services = services
    }

    var selectedImage: DatasetImage? {
        selectedImageID.flatMap { imagesByID[$0] }
    }

    var selectedAnnotation: DatasetAnnotation? {
        selectedAnnotationID.flatMap { annotationsByID[$0] }
    }

    var annotationsForSelectedImage: [DatasetAnnotation] {
        guard let selectedImageID else { return [] }
        return annotationsByImageID[selectedImageID] ?? []
    }

    var filteredImages: [DatasetImage] {
        if cachedFilterRevision == filterRevision { return cachedFilteredImages }
        guard let dataset else {
            cachedFilteredImages = []
            cachedFilterRevision = filterRevision
            return []
        }
        let query = searchText
        let includedCategoryIDs = self.includedCategoryIDs
        let excludedCategoryIDs = self.excludedCategoryIDs
        let result = dataset.images.filter { image in
            let splitMatches: Bool
            switch splitFilter {
            case .all: splitMatches = true
            case .train: splitMatches = image.split == .train
            case .validation: splitMatches = image.split == .validation
            case .test: splitMatches = image.split == .test
            }
            guard splitMatches else { return false }

            let imageAnnotations = annotationsByImageID[image.id] ?? []
            let statusMatches: Bool = switch statusFilter {
            case .all: true
            case .unannotated: imageAnnotations.isEmpty
            case .annotated: !imageAnnotations.isEmpty
            case .suggestions: imageAnnotations.contains { $0.source == .aiSuggestion }
            }
            guard statusMatches else { return false }

            let queryMatches = query.isEmpty
                || image.fileName.localizedCaseInsensitiveContains(query)
                || imageAnnotations.contains { annotation in
                    categoryNamesByID[annotation.categoryID]?.localizedCaseInsensitiveContains(query) == true
                }
            guard queryMatches else { return false }

            guard !includedCategoryIDs.isEmpty || !excludedCategoryIDs.isEmpty else { return true }
            let imageCategoryIDs = Set(imageAnnotations.lazy.map(\.categoryID))
            return imageCategoryIDs.isDisjoint(with: excludedCategoryIDs)
                && (includedCategoryIDs.isEmpty || includedCategoryIDs.isSubset(of: imageCategoryIDs))
        }
        cachedFilteredImages = result
        cachedFilterRevision = filterRevision
        return result
    }

    var browserImages: [DatasetImage] {
        if cachedBrowserRevision == filterRevision,
           cachedBrowserSortKey == imageSortKey,
           cachedBrowserSortAscending == imageSortAscending {
            return cachedBrowserImages
        }
        let result = filteredImages.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch imageSortKey {
            case .name: comparison = lhs.fileName.localizedStandardCompare(rhs.fileName)
            case .size:
                let left = Int64(lhs.size.width) * Int64(lhs.size.height)
                let right = Int64(rhs.size.width) * Int64(rhs.size.height)
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .split:
                let order: [DatasetSplit: Int] = [.train: 0, .validation: 1, .test: 2, .unassigned: 3]
                let left = order[lhs.split, default: 99], right = order[rhs.split, default: 99]
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .labels:
                let left = annotationCount(for: lhs.id), right = annotationCount(for: rhs.id)
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame { return lhs.id.uuidString < rhs.id.uuidString }
            return imageSortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        cachedBrowserImages = result
        cachedBrowserRevision = filterRevision
        cachedBrowserSortKey = imageSortKey
        cachedBrowserSortAscending = imageSortAscending
        return result
    }

    func imageURL(for image: DatasetImage) -> URL? {
        dataset?.rootURL?.appending(path: image.relativePath)
    }

    func annotationCount(for imageID: UUID) -> Int {
        annotationsByImageID[imageID]?.count ?? 0
    }

    func annotationCount(forCategoryID categoryID: UUID) -> Int {
        annotationCountsByCategoryID[categoryID] ?? 0
    }

    func neighborImageURLs() -> [URL] {
        let images = filteredImages
        guard let selectedImageID, let index = images.firstIndex(where: { $0.id == selectedImageID }) else { return [] }
        return [index - 1, index + 1].compactMap { neighborIndex in
            guard images.indices.contains(neighborIndex) else { return nil }
            return imageURL(for: images[neighborIndex])
        }
    }

    func attachUndoManager(_ manager: UndoManager?) {
        undoManager = manager
    }

    func openDataset() {
        let panel = NSOpenPanel()
        panel.title = "Open Dataset"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(title: "Opening dataset") { [services] in try await services.openDataset(at: url) } completion: { [weak self] dataset in
            self?.replaceDataset(dataset)
        }
    }

    func openDroppedURL(_ url: URL) {
        perform(title: "Opening dataset") { [services] in try await services.openDataset(at: url) } completion: { [weak self] dataset in
            self?.replaceDataset(dataset)
        }
    }

    func createDataset() {
        let panel = NSSavePanel()
        panel.title = "Create Dataset"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled Dataset"
        panel.canCreateDirectories = true
        let formatAccessory = DatasetFormatAccessoryView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        panel.accessoryView = formatAccessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = formatAccessory.selectedFormat
        perform(title: "Creating dataset") { [services] in
            try await services.createDataset(named: url.lastPathComponent, at: url, syncFormat: format)
        } completion: { [weak self] dataset in
            self?.replaceDataset(dataset)
        }
    }

    func addImages() {
        guard let dataset else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Images"
        panel.prompt = "Add"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        perform(title: "Adding images") { [services] in
            try await services.addImages(panel.urls, to: dataset)
        } completion: { [weak self] dataset in
            self?.replaceDataset(dataset)
            self?.markDirty()
        }
    }

    func importDataset() {
        let panel = NSOpenPanel()
        panel.title = "Import YOLO or COCO Dataset"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(title: "Importing dataset") { [services] in try await services.importDataset(from: url) } completion: { [weak self] dataset in
            self?.replaceDataset(dataset)
        }
    }

    func importIntoCurrentDataset() {
        guard let dataset else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Into Current Dataset"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(title: "Merging dataset") { [services] in
            try await services.mergeDataset(from: url, into: dataset)
        } completion: { [weak self] merged in
            self?.dataset = merged
            self?.selectedImageID = merged.images.last?.id
            self?.selectedImageIDs = merged.images.last.map { [$0.id] } ?? []
            self?.selectedCategoryID = merged.categories.first?.id
            self?.markDirty()
        }
    }

    func exportDataset() {
        guard let dataset else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(title: "Exporting dataset") { [services] in
            try await services.export(dataset, to: url)
            return true
        } completion: { _ in }
    }

    func save() {
        guard let dataset, isDirty else { return }
        perform(title: "Saving", showsProgress: false) { [services] in
            try await services.save(dataset)
            return true
        } completion: { [weak self] _ in
            self?.isDirty = false
        }
    }

    func validate() {
        guard let dataset else { return }
        perform(title: "Validating") { [services] in try await services.validate(dataset) } completion: { [weak self] summary in
            self?.validation = summary
        }
    }

    func runInference() {
        guard let dataset, let image = selectedImage else { return }
        perform(title: "Running local AI") { [services] in
            try await services.runInference(for: image, in: dataset)
        } completion: { [weak self] suggestions in
            guard let self, var dataset = self.dataset else { return }
            dataset.annotations.append(contentsOf: suggestions)
            self.dataset = dataset
            self.markDirty()
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        operation = nil
    }

    func selectImage(_ id: UUID?) {
        selectedImageID = id
        selectedImageIDs = id.map { [$0] } ?? []
        selectionAnchorImageID = id
        selectedAnnotationID = nil
    }

    func selectImage(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let images = browserImages
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        if shift, let anchor = selectionAnchorImageID,
           let start = images.firstIndex(where: { $0.id == anchor }),
           let end = images.firstIndex(where: { $0.id == id }) {
            let range = Set(images[min(start, end)...max(start, end)].map(\.id))
            selectedImageIDs.formUnion(range)
        } else if command {
            if selectedImageIDs.contains(id) { selectedImageIDs.remove(id) } else { selectedImageIDs.insert(id) }
        } else {
            selectedImageIDs = [id]
        }
        selectedImageID = id
        selectionAnchorImageID = id
        selectedAnnotationID = nil
    }

    func selectImages(_ ids: Set<UUID>) {
        let added = ids.subtracting(selectedImageIDs).first
        selectedImageIDs = ids
        selectedImageID = added ?? selectedImageID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        selectionAnchorImageID = selectedImageID
        selectedAnnotationID = nil
    }

    func toggleSort(_ key: ImageSortKey) {
        if imageSortKey == key { imageSortAscending.toggle() } else { imageSortKey = key; imageSortAscending = true }
        invalidateFilteredImages()
    }

    func setSplit(_ split: DatasetSplit, for ids: Set<UUID>? = nil) {
        guard var dataset else { return }
        let targetIDs = ids ?? selectedImageIDs
        guard !targetIDs.isEmpty else { return }
        var changed = false
        for index in dataset.images.indices where targetIDs.contains(dataset.images[index].id) {
            if dataset.images[index].split != split { dataset.images[index].split = split; changed = true }
        }
        guard changed else { return }
        self.dataset = dataset
        markDirty()
    }

    func smartSplit(trainRatio: Double, validationRatio: Double) {
        guard let dataset else { return }
        perform(title: "Smart splitting dataset") { [services] in
            try await services.smartSplit(dataset, trainRatio: trainRatio, validationRatio: validationRatio)
        } completion: { [weak self] result in
            self?.dataset = result
            self?.markDirty()
        }
    }

    func navigate(_ offset: Int) {
        let images = filteredImages
        guard !images.isEmpty else { return }
        let current = images.firstIndex { $0.id == selectedImageID } ?? (offset > 0 ? -1 : images.count)
        let destination = min(max(current + offset, 0), images.count - 1)
        selectImage(images[destination].id)
    }

    func createAnnotation(geometry: AnnotationGeometry) {
        guard var dataset, let imageID = selectedImageID, let categoryID = selectedCategoryID ?? dataset.categories.first?.id else { return }
        let annotation = DatasetAnnotation(
            id: UUID(),
            imageID: imageID,
            categoryID: categoryID,
            geometry: geometry,
            attributes: AnnotationAttributes(),
            source: .manual,
            isVisible: true,
            isLocked: false
        )
        dataset.annotations.append(annotation)
        self.dataset = dataset
        selectedAnnotationID = annotation.id
        registerUndo(action: "Create Annotation") { model in model.deleteAnnotation(id: annotation.id, registeringUndo: false) }
        markDirty()
    }

    func updateGeometry(id: UUID, from oldGeometry: AnnotationGeometry, to geometry: AnnotationGeometry, action: String) {
        setGeometry(id: id, geometry: geometry)
        registerUndo(action: action) { model in
            model.setGeometry(id: id, geometry: oldGeometry)
            model.registerUndo(action: action) { redoModel in redoModel.setGeometry(id: id, geometry: geometry) }
        }
        markDirty()
    }

    func setGeometry(id: UUID, geometry: AnnotationGeometry) {
        guard var dataset, let index = dataset.annotations.firstIndex(where: { $0.id == id }) else { return }
        dataset.annotations[index].geometry = geometry
        self.dataset = dataset
    }

    func deleteSelection() {
        guard let selectedAnnotationID else { return }
        deleteAnnotation(id: selectedAnnotationID)
    }

    func deleteAnnotation(id: UUID, registeringUndo: Bool = true) {
        guard var dataset, let index = dataset.annotations.firstIndex(where: { $0.id == id }) else { return }
        let removed = dataset.annotations.remove(at: index)
        self.dataset = dataset
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        if registeringUndo {
            registerUndo(action: "Delete Annotation") { model in model.restoreAnnotation(removed) }
        }
        markDirty()
    }

    func restoreAnnotation(_ annotation: DatasetAnnotation) {
        guard var dataset else { return }
        dataset.annotations.append(annotation)
        self.dataset = dataset
        selectedAnnotationID = annotation.id
        registerUndo(action: "Delete Annotation") { model in model.deleteAnnotation(id: annotation.id, registeringUndo: false) }
        markDirty()
    }

    func updateSelectedCategory(_ categoryID: UUID) {
        guard var dataset, let id = selectedAnnotationID, let index = dataset.annotations.firstIndex(where: { $0.id == id }) else { return }
        let oldID = dataset.annotations[index].categoryID
        dataset.annotations[index].categoryID = categoryID
        self.dataset = dataset
        registerUndo(action: "Change Class") { model in model.setCategory(oldID, annotationID: id) }
        markDirty()
    }

    func setCategory(_ categoryID: UUID, annotationID: UUID) {
        guard var dataset, let index = dataset.annotations.firstIndex(where: { $0.id == annotationID }) else { return }
        dataset.annotations[index].categoryID = categoryID
        self.dataset = dataset
        markDirty()
    }

    func toggleVisibility() {
        guard var dataset, let id = selectedAnnotationID, let index = dataset.annotations.firstIndex(where: { $0.id == id }) else { return }
        dataset.annotations[index].isVisible.toggle()
        self.dataset = dataset
        markDirty()
    }

    func toggleLock() {
        guard var dataset, let id = selectedAnnotationID, let index = dataset.annotations.firstIndex(where: { $0.id == id }) else { return }
        dataset.annotations[index].isLocked.toggle()
        self.dataset = dataset
        markDirty()
    }

    func acceptSelectedSuggestion() {
        guard var dataset, let id = selectedAnnotationID, let index = dataset.annotations.firstIndex(where: { $0.id == id }), dataset.annotations[index].source == .aiSuggestion else { return }
        dataset.annotations[index].source = .aiAccepted
        self.dataset = dataset
        markDirty()
    }

    func removeSuggestions() {
        guard var dataset, let imageID = selectedImageID else { return }
        dataset.annotations.removeAll { $0.imageID == imageID && $0.source == .aiSuggestion }
        self.dataset = dataset
        if selectedAnnotation?.source == .aiSuggestion { selectedAnnotationID = nil }
        markDirty()
    }

    func addCategory(name: String, colorHex: String) {
        guard var dataset else { return }
        let category = DatasetCategory(name: name, colorHex: colorHex)
        dataset.categories.append(category)
        self.dataset = dataset
        selectedCategoryID = category.id
        markDirty()
    }

    func updateCategory(id: UUID, name: String? = nil, colorHex: String? = nil) {
        guard var dataset, let index = dataset.categories.firstIndex(where: { $0.id == id }) else { return }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dataset.categories[index].name = name }
        if let colorHex { dataset.categories[index].colorHex = colorHex }
        self.dataset = dataset
        markDirty()
    }

    func deleteImage(id: UUID, registeringUndo: Bool = true) {
        guard var dataset, let index = dataset.images.firstIndex(where: { $0.id == id }) else { return }
        if let root = dataset.rootURL {
            let imageURL = root.appendingPathComponent(dataset.images[index].relativePath)
            if FileManager.default.fileExists(atPath: imageURL.path) {
                do {
                    try FileManager.default.trashItem(at: imageURL, resultingItemURL: nil)
                } catch {
                    alertMessage = "Could not move \(dataset.images[index].fileName) to the Trash: \(error.localizedDescription)"
                    return
                }
            }
        }
        let wasSelected = selectedImageID == id
        let removed = dataset.images.remove(at: index)
        let removedAnnotations = dataset.annotations.filter { $0.imageID == id }
        dataset.annotations.removeAll { $0.imageID == id }
        self.dataset = dataset
        if wasSelected {
            let images = filteredImages
            let neighbor = images.indices.contains(index - 1) ? images[index - 1] : (images.indices.contains(index) ? images[index] : images.last)
            selectImage(neighbor?.id)
        }
        if registeringUndo {
            registerUndo(action: "Delete Image") { model in model.restoreImage(removed, annotations: removedAnnotations) }
        }
        markDirty()
    }

    func deleteSelectedImages() {
        deleteImages(ids: selectedImageIDs)
    }

    func deleteImages(ids: Set<UUID>, registeringUndo: Bool = true) {
        guard let dataset, !ids.isEmpty else { return }
        let removedImages = dataset.images.filter { ids.contains($0.id) }
        guard !removedImages.isEmpty else { return }
        let root = dataset.rootURL
        perform(title: "Moving \(removedImages.count) \(removedImages.count == 1 ? "image" : "images") to Trash") { [removedImages, root] in
            try await Task.detached(priority: .userInitiated) {
                guard let root else { return }
                for image in removedImages {
                    try Task.checkCancellation()
                    let imageURL = root.appendingPathComponent(image.relativePath)
                    if FileManager.default.fileExists(atPath: imageURL.path) {
                        try FileManager.default.trashItem(at: imageURL, resultingItemURL: nil)
                    }
                }
            }.value
        } completion: { [weak self, removedImages, root] in
            guard let self, self.dataset?.rootURL == root else { return }
            self.finishDeletingImages(removedImages, registeringUndo: registeringUndo)
        }
    }

    private func finishDeletingImages(_ removedImages: [DatasetImage], registeringUndo: Bool) {
        guard var dataset else { return }
        let removedIDs = Set(removedImages.map(\.id))
        let removedAnnotations = dataset.annotations.filter { removedIDs.contains($0.imageID) }
        dataset.images.removeAll { removedIDs.contains($0.id) }
        dataset.annotations.removeAll { removedIDs.contains($0.imageID) }
        self.dataset = dataset
        selectedImageIDs.subtract(removedIDs)
        if let selectedImageID, removedIDs.contains(selectedImageID) {
            let next = browserImages.first
            self.selectedImageID = next?.id
            if let next { selectedImageIDs.insert(next.id) }
        }
        if registeringUndo {
            registerUndo(action: removedImages.count == 1 ? "Delete Image" : "Delete Images") { model in
                model.restoreImages(removedImages, annotations: removedAnnotations)
            }
        }
        markDirty()
    }

    func restoreImage(_ image: DatasetImage, annotations: [DatasetAnnotation]) {
        guard var dataset else { return }
        dataset.images.append(image)
        dataset.annotations.append(contentsOf: annotations)
        self.dataset = dataset
        selectImage(image.id)
        registerUndo(action: "Delete Image") { model in model.deleteImage(id: image.id, registeringUndo: false) }
        markDirty()
    }

    func restoreImages(_ images: [DatasetImage], annotations: [DatasetAnnotation]) {
        guard var dataset else { return }
        dataset.images.append(contentsOf: images)
        dataset.annotations.append(contentsOf: annotations)
        self.dataset = dataset
        selectedImageID = images.first?.id
        selectedImageIDs = Set(images.map(\.id))
        registerUndo(action: images.count == 1 ? "Delete Image" : "Delete Images") { model in
            model.deleteImages(ids: Set(images.map(\.id)), registeringUndo: false)
        }
        markDirty()
    }

    func deleteCategory(id: UUID) {
        guard var dataset else { return }
        dataset.annotations.removeAll { $0.categoryID == id }
        dataset.categories.removeAll { $0.id == id }
        self.dataset = dataset
        selectedCategoryID = dataset.categories.first?.id
        selectedAnnotationID = nil
        includedCategoryIDs.remove(id)
        excludedCategoryIDs.remove(id)
        markDirty()
    }

    func toggleIncludeCategory(_ id: UUID) {
        if includedCategoryIDs.contains(id) {
            includedCategoryIDs.remove(id)
        } else {
            includedCategoryIDs.insert(id)
            excludedCategoryIDs.remove(id)
        }
    }

    func toggleExcludeCategory(_ id: UUID) {
        if excludedCategoryIDs.contains(id) {
            excludedCategoryIDs.remove(id)
        } else {
            excludedCategoryIDs.insert(id)
            includedCategoryIDs.remove(id)
        }
    }

    func clearCategoryFilters() {
        includedCategoryIDs.removeAll()
        excludedCategoryIDs.removeAll()
    }

    func loadModel() {
        let panel = NSOpenPanel()
        panel.title = "Load Core ML Model"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mlmodel", conformingTo: .data)!,
            UTType(filenameExtension: "mlpackage", conformingTo: .package)!,
            UTType(filenameExtension: "mlmodelc", conformingTo: .package)!
        ]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(title: "Loading model") { [services] in
            try await services.loadModel(from: url)
            return url.lastPathComponent
        } completion: { [weak self] name in self?.alertMessage = "Loaded \(name)." }
    }

    func fitImage() {
        viewport.fitRequest += 1
    }

    func actualSize() {
        viewport.zoom = 1
        viewport.pan = .zero
    }

    private func replaceDataset(_ dataset: AnnotationDataset) {
        self.dataset = dataset
        selectedImageID = dataset.images.first?.id
        selectedImageIDs = dataset.images.first.map { [$0.id] } ?? []
        selectionAnchorImageID = selectedImageID
        selectedCategoryID = dataset.categories.first?.id
        selectedAnnotationID = nil
        includedCategoryIDs.removeAll()
        excludedCategoryIDs.removeAll()
        isDirty = false
        validation = ValidationSummary()
        fitImage()
    }

    private func markDirty() {
        isDirty = true
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // Used by small view-local mutations that do not have a dedicated command method.
    func markDirtyForExternalMutation() {
        markDirty()
    }

    private func rebuildIndexes() {
        guard let dataset else {
            imagesByID = [:]
            annotationsByID = [:]
            annotationsByImageID = [:]
            annotationCountsByCategoryID = [:]
            categoryNamesByID = [:]
            return
        }
        imagesByID = Dictionary(uniqueKeysWithValues: dataset.images.map { ($0.id, $0) })
        annotationsByID = Dictionary(uniqueKeysWithValues: dataset.annotations.map { ($0.id, $0) })
        annotationsByImageID = Dictionary(grouping: dataset.annotations, by: \.imageID)
        annotationCountsByCategoryID = dataset.annotations.reduce(into: [:]) { $0[$1.categoryID, default: 0] += 1 }
        categoryNamesByID = Dictionary(uniqueKeysWithValues: dataset.categories.map { ($0.id, $0.name) })
    }

    private func invalidateFilteredImages() {
        filterRevision &+= 1
        browserDataRevision &+= 1
        cachedBrowserRevision = -1
    }

    private func registerUndo(action: String, operation: @escaping @MainActor (AppModel) -> Void) {
        undoManager?.registerUndo(withTarget: self) { model in
            Task { @MainActor in operation(model) }
        }
        undoManager?.setActionName(action)
    }

    private func perform<Value: Sendable>(
        title: String,
        showsProgress: Bool = true,
        operation body: @escaping @Sendable () async throws -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) {
        operationTask?.cancel()
        if showsProgress { operation = OperationProgress(title: title, completed: 0, isCancellable: true) }
        operationTask = Task { [weak self] in
            do {
                let value = try await body()
                guard !Task.isCancelled else { return }
                completion(value)
            } catch is CancellationError {
                // Cancellation is directly initiated by the user and needs no alert.
            } catch {
                self?.alertMessage = error.localizedDescription
            }
            self?.operation = nil
            self?.operationTask = nil
        }
    }
}
