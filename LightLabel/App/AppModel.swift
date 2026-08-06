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
    case pan = "Pan"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .select: "arrow.up.left"
        case .box: "rectangle.dashed"
        case .polygon: "point.3.connected.trianglepath.dotted"
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
    case reviewed = "Reviewed"
    case suggestions = "AI suggestions"

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
    func createDataset(named name: String, at url: URL) async throws -> AnnotationDataset
    func addImages(_ urls: [URL], to dataset: AnnotationDataset) async throws -> AnnotationDataset
    func save(_ dataset: AnnotationDataset) async throws
    func importDataset(from url: URL) async throws -> AnnotationDataset
    func export(_ dataset: AnnotationDataset, to url: URL) async throws
    func validate(_ dataset: AnnotationDataset) async throws -> ValidationSummary
    func runInference(for image: DatasetImage, in dataset: AnnotationDataset) async throws -> [DatasetAnnotation]
    func loadModel(from url: URL) async throws
}

struct LocalDatasetServices: DatasetApplicationServices {
    private let inferenceStore = LocalInferenceStore()

    func openDataset(at url: URL) async throws -> AnnotationDataset {
        let persistence = ProjectPersistence(directoryURL: url.appendingPathComponent(".lightlabel"))
        if let saved = try? await persistence.loadDataset() { return saved.withRootURL(url) }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("data.yaml").path) {
            return try YOLOImporter().importDataset(at: url).dataset.withRootURL(url)
        }
        let candidates = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "json" }
        guard let json = candidates.first else { throw DatasetFormatError.unreadableFile("data.yaml or COCO JSON") }
        return try COCOImporter().importDataset(at: json, imageRoot: url).dataset.withRootURL(url)
    }

    func createDataset(named name: String, at url: URL) async throws -> AnnotationDataset {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dataset = AnnotationDataset(name: name).withRootURL(url)
        try await ProjectPersistence(directoryURL: url.appendingPathComponent(".lightlabel")).save(dataset)
        return dataset
    }

    func addImages(_ urls: [URL], to dataset: AnnotationDataset) async throws -> AnnotationDataset {
        guard let root = dataset.rootURL else { throw DatasetFormatError.invalidData("Dataset has no root folder") }
        let directory = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var updated = dataset
        for source in urls {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
            guard let size = Self.imageSize(at: destination) else { continue }
            let relativePath = "images/\(destination.lastPathComponent)"
            guard !updated.images.contains(where: { $0.relativePath == relativePath }) else { continue }
            updated.images.append(.init(fileName: destination.lastPathComponent, relativePath: relativePath, size: size))
        }
        return updated
    }

    func save(_ dataset: AnnotationDataset) async throws {
        guard let root = dataset.rootURL else { throw DatasetFormatError.invalidData("Dataset has no root folder") }
        try await ProjectPersistence(directoryURL: root.appendingPathComponent(".lightlabel")).save(dataset)
    }

    func importDataset(from url: URL) async throws -> AnnotationDataset {
        if url.pathExtension.lowercased() == "json" {
            return try COCOImporter().importDataset(at: url, imageRoot: url.deletingLastPathComponent()).dataset.withRootURL(url.deletingLastPathComponent())
        }
        return try YOLOImporter().importDataset(at: url).dataset.withRootURL(url)
    }

    func export(_ dataset: AnnotationDataset, to url: URL) async throws {
        switch await ExportChoiceDialog.present() {
        case .yoloDetection: _ = try YOLOExporter().export(dataset, to: url, task: .detection)
        case .yoloSegmentation: _ = try YOLOExporter().export(dataset, to: url, task: .segmentation)
        case .coco: _ = try COCOExporter().export(dataset, to: url.appendingPathComponent("annotations.json"))
        case .cancel: throw CancellationError()
        }
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
}

actor LocalInferenceStore {
    private var engine: (any ImageInferenceEngine)?
    func load(_ url: URL) throws {
        let modelURL: URL
        if url.pathExtension.lowercased() == "mlmodelc" { modelURL = url }
        else { modelURL = try MLModel.compileModel(at: url) }
        let model = try MLModel(contentsOf: modelURL)
        engine = try VisionCoreMLInferenceEngine(model: model)
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

extension AnnotationDataset {
    func withRootURL(_ url: URL) -> Self {
        var copy = self
        copy.metadata["lightlabel.rootURL"] = url.standardizedFileURL.path
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
    var dataset: AnnotationDataset?
    var selectedImageID: UUID?
    var selectedAnnotationID: UUID?
    var selectedCategoryID: UUID?
    var tool = AnnotationTool.select
    var browserMode = BrowserMode.workspace
    var splitFilter = SplitFilter.all
    var statusFilter = StatusFilter.all
    var searchText = ""
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

    init(services: any DatasetApplicationServices = LocalDatasetServices()) {
        self.services = services
    }

    var selectedImage: DatasetImage? {
        dataset?.images.first { $0.id == selectedImageID }
    }

    var selectedAnnotation: DatasetAnnotation? {
        dataset?.annotations.first { $0.id == selectedAnnotationID }
    }

    var annotationsForSelectedImage: [DatasetAnnotation] {
        guard let selectedImageID else { return [] }
        return dataset?.annotations.filter { $0.imageID == selectedImageID } ?? []
    }

    var filteredImages: [DatasetImage] {
        guard let dataset else { return [] }
        return dataset.images.filter { image in
            let splitMatches = splitFilter == .all || String(describing: image.split).localizedCaseInsensitiveContains(splitFilter.rawValue)
            let imageAnnotations = dataset.annotations.filter { $0.imageID == image.id }
            let review = String(describing: image.reviewState)
            let statusMatches: Bool = switch statusFilter {
            case .all: true
            case .unannotated: imageAnnotations.isEmpty
            case .annotated: !imageAnnotations.isEmpty
            case .reviewed: review.localizedCaseInsensitiveContains("reviewed") && !review.localizedCaseInsensitiveContains("unreviewed")
            case .suggestions: imageAnnotations.contains { $0.source == .aiSuggestion }
            }
            let queryMatches = searchText.isEmpty
                || image.fileName.localizedCaseInsensitiveContains(searchText)
                || imageAnnotations.contains { annotation in
                    dataset.categories.first(where: { $0.id == annotation.categoryID })?.name.localizedCaseInsensitiveContains(searchText) == true
                }
            return splitMatches && statusMatches && queryMatches
        }
    }

    func imageURL(for image: DatasetImage) -> URL? {
        dataset?.rootURL?.appending(path: image.relativePath)
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(title: "Creating dataset") { [services] in
            try await services.createDataset(named: url.lastPathComponent, at: url)
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
        selectedAnnotationID = nil
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

    func deleteCategory(id: UUID) {
        guard var dataset else { return }
        dataset.annotations.removeAll { $0.categoryID == id }
        dataset.categories.removeAll { $0.id == id }
        self.dataset = dataset
        selectedCategoryID = dataset.categories.first?.id
        selectedAnnotationID = nil
        markDirty()
    }

    func setReviewState(_ state: ReviewState) {
        guard var dataset, let id = selectedImageID, let index = dataset.images.firstIndex(where: { $0.id == id }) else { return }
        dataset.images[index].reviewState = state
        self.dataset = dataset
        markDirty()
    }

    func loadModel() {
        let panel = NSOpenPanel()
        panel.title = "Load Core ML Model"
        panel.allowedContentTypes = [.init(filenameExtension: "mlmodel") ?? .data, .init(filenameExtension: "mlpackage") ?? .package, .init(filenameExtension: "mlmodelc") ?? .data]
        panel.canChooseDirectories = true
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
        selectedCategoryID = dataset.categories.first?.id
        selectedAnnotationID = nil
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
