import SwiftUI

struct AnnotationWorkspace: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { model.navigate(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                Button { model.navigate(1) } label: { Label("Next", systemImage: "chevron.right") }
                Divider().frame(height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedImage?.fileName ?? "No image selected").fontWeight(.semibold).lineLimit(1)
                    if let image = model.selectedImage { Text("\(image.size.width) × \(image.size.height) px").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(model.annotationsForSelectedImage.count) annotations").foregroundStyle(.secondary)
                Button { model.showLabels.toggle() } label: { Image(systemName: model.showLabels ? "tag" : "tag.slash") }
                    .help("Show labels")
                Button { model.fitImage() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit image")
                Button { model.actualSize() } label: { Text("1:1").font(.caption.monospaced()) }.help("Actual size")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.bar)
            Divider()
            if model.selectedImage != nil {
                AnnotationCanvas(model: model)
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                ContentUnavailableView("Select an image", systemImage: "photo", description: Text("Choose an image from the grid or list."))
            }
        }
        .navigationTitle(model.selectedImage?.fileName ?? "Workspace")
    }
}

struct AnnotationInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            if let annotation = model.selectedAnnotation {
                Section("Annotation") {
                    LabeledContent("ID") { Text(annotation.id.uuidString.prefix(8)).font(.caption.monospaced()).textSelection(.enabled) }
                    Picker("Class", selection: Binding(get: { annotation.categoryID }, set: { categoryID in MainActor.assumeIsolated { model.updateSelectedCategory(categoryID) } })) {
                        ForEach(model.dataset?.categories ?? []) { Text($0.name).tag($0.id) }
                    }
                    LabeledContent("Geometry", value: geometryName(annotation.geometry))
                    if let box = annotation.geometry.bounds {
                        LabeledContent("Position", value: String(format: "%.3f, %.3f", box.x, box.y))
                        LabeledContent("Size", value: String(format: "%.3f × %.3f", box.width, box.height))
                    }
                    if case let .polygon(polygon) = annotation.geometry { LabeledContent("Vertices", value: polygon.points.count.formatted()) }
                    if let confidence = annotation.attributes.confidence { LabeledContent("Confidence", value: String(format: "%.0f%%", confidence * 100)) }
                    LabeledContent("Source", value: annotation.source.rawValue.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized)
                    if annotation.source == .aiSuggestion {
                        HStack {
                            Button("Accept", systemImage: "checkmark") { model.acceptSelectedSuggestion() }
                            Button("Reject", systemImage: "xmark", role: .destructive) { model.deleteSelection() }
                        }
                    }
                    Toggle("Visible", isOn: Binding(get: { annotation.isVisible }, set: { _ in model.toggleVisibility() }))
                    Toggle("Locked", isOn: Binding(get: { annotation.isLocked }, set: { _ in model.toggleLock() }))
                    HStack {
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(annotation) }
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive, action: model.deleteSelection)
                    }
                }
            } else {
                Section("Annotation") { Text("Select an annotation on the canvas to inspect it.").foregroundStyle(.secondary) }
            }
            if let image = model.selectedImage {
                Section("Image") {
                    LabeledContent("Filename", value: image.fileName)
                    LabeledContent("Dimensions", value: "\(image.size.width) × \(image.size.height)")
                    Picker("Review", selection: Binding(get: { image.reviewState }, set: { state in MainActor.assumeIsolated { model.setReviewState(state) } })) {
                        ForEach(ReviewState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        if let url = model.imageURL(for: image) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            Section("AI Assistant") {
                Button("Load Core ML Model…", systemImage: "cube") { model.loadModel() }
                Button("Run on Current Image", systemImage: "sparkles") { model.runInference() }.disabled(model.selectedImage == nil)
                Button("Remove Suggestions", systemImage: "sparkles.square.filled.on.square") { model.removeSuggestions() }.disabled(!model.annotationsForSelectedImage.contains { $0.source == .aiSuggestion })
                Text("Suggestions remain editable until accepted.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Validation") {
                Label(model.validation.message, systemImage: "checkmark.shield")
                if model.validation.errors > 0 { Text("\(model.validation.errors) errors").foregroundStyle(.red) }
                if model.validation.warnings > 0 { Text("\(model.validation.warnings) warnings").foregroundStyle(.orange) }
                Button("Run Validation", action: model.validate)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Inspector")
    }

    private func geometryName(_ geometry: AnnotationGeometry) -> String {
        switch geometry { case .boundingBox: "Bounding box"; case .polygon: "Polygon" }
    }

    private func duplicate(_ annotation: DatasetAnnotation) {
        guard var dataset = model.dataset else { return }
        var copy = annotation; copy.id = UUID(); copy.source = .manual
        if case let .boundingBox(box) = copy.geometry { copy.geometry = .boundingBox(BoundingBox(x: min(box.x + 0.02, 1 - box.width), y: min(box.y + 0.02, 1 - box.height), width: box.width, height: box.height)) }
        dataset.annotations.append(copy); model.dataset = dataset; model.selectedAnnotationID = copy.id
    }
}
