import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            DatasetSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 310)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 520, ideal: 900)
        } detail: {
            if model.inspectorVisible {
                AnnotationInspector(model: model)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 285, max: 340)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbar }
        .onAppear { model.attachUndoManager(undoManager) }
        .onChange(of: undoManager) { _, value in model.attachUndoManager(value) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.openDroppedURL(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .alert("LightLabel", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "An unknown error occurred.")
        }
        .overlay(alignment: .bottom) {
            if let operation = model.operation {
                OperationBanner(operation: operation, cancel: model.cancelOperation)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.dataset == nil {
            WelcomeView(model: model)
        } else {
            switch model.browserMode {
            case .workspace: AnnotationWorkspace(model: model)
            case .grid: DatasetGrid(model: model)
            case .list: DatasetList(model: model)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Browser mode", selection: $model.browserMode) {
                Label("Workspace", systemImage: "rectangle.inset.filled").tag(BrowserMode.workspace)
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserMode.grid)
                Label("List", systemImage: "list.bullet").tag(BrowserMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .disabled(model.dataset == nil)
        }
        ToolbarItemGroup(placement: .principal) {
            if model.browserMode == .workspace, model.dataset != nil {
                Picker("Annotation tool", selection: $model.tool) {
                    ForEach(AnnotationTool.allCases) { tool in
                        Label(tool.rawValue, systemImage: tool.symbol).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                .help(model.tool == .smartPolygon ? "Click an object to generate an editable mask polygon" : "Choose an annotation tool")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.browserMode == .grid {
                Menu {
                    Picker("Sort by", selection: Binding(get: { model.imageSortKey }, set: { model.toggleSort($0) })) {
                        ForEach(ImageSortKey.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Button(model.imageSortAscending ? "Sort Descending" : "Sort Ascending") {
                        model.imageSortAscending.toggle()
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort images like Finder")
            }
            if !model.selectedImageIDs.isEmpty {
                Menu {
                    ForEach([DatasetSplit.train, .validation, .test, .unassigned], id: \.self) { split in
                        Button(split == .unassigned ? "Unassigned" : split.yoloName.capitalized) {
                            model.setSplit(split)
                        }
                    }
                } label: {
                    Label("Set Split", systemImage: "arrow.triangle.branch")
                }
                Button(role: .destructive) { model.deleteSelectedImages() } label: {
                    Label("Trash \(model.selectedImageIDs.count == 1 ? "Image" : "Images")", systemImage: "trash")
                }
            }
            Button { model.runInference() } label: {
                Label("Run AI", systemImage: "sparkles")
            }
            .disabled(model.selectedImage == nil || model.operation != nil)
            .help("Run local inference on this image")
            Button { model.inspectorVisible.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(model.inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
    }
}

private struct OperationBanner: View {
    let operation: OperationProgress
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(operation.title).fontWeight(.medium)
            if operation.isCancellable {
                Button("Cancel", action: cancel).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("LightLabel", systemImage: "viewfinder.rectangular")
                .accessibilityIdentifier("welcome.title")
        } description: {
            Text("Fast, private annotation for object detection and instance segmentation. Your images stay on this Mac.")
                .frame(maxWidth: 430)
                .accessibilityIdentifier("welcome.privacy")
        } actions: {
            HStack {
                Button("Create Dataset", action: model.createDataset).accessibilityIdentifier("welcome.createDataset")
                Button("Open Dataset…", action: model.openDataset).buttonStyle(.borderedProminent).accessibilityIdentifier("welcome.openDataset")
            }
        }
    }
}
