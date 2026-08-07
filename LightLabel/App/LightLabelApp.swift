import SwiftUI

@main
struct LightLabelApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            LightLabelCommands(model: model)
        }
    }
}

struct LightLabelCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Dataset…") { model.createDataset() }
                .keyboardShortcut("n")
            Button("Open Dataset…") { model.openDataset() }
                .keyboardShortcut("o")
            Divider()
            Button("Add Images…") { model.addImages() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model.dataset == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(model.dataset == nil)
            Button("Export Dataset…") { model.exportDataset() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.dataset == nil)
        }
        CommandMenu("Annotation") {
            Button("Selection Tool") { model.tool = .select }.keyboardShortcut("v", modifiers: [])
            Button("Bounding Box Tool") { model.tool = .box }.keyboardShortcut("b", modifiers: [])
            Button("Polygon Tool") { model.tool = .polygon }.keyboardShortcut("p", modifiers: [])
            Button("Smart Polygon Tool") { model.tool = .smartPolygon }.keyboardShortcut("s", modifiers: [])
            Button("Pan Tool") { model.tool = .pan }.keyboardShortcut("h", modifiers: [])
            Divider()
            Button("Previous Image") { model.navigate(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Image") { model.navigate(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Fit Image") { model.fitImage() }.keyboardShortcut("f", modifiers: [])
            Button("Actual Size") { model.actualSize() }.keyboardShortcut("1", modifiers: [])
            Divider()
            Button("Delete Annotation") { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selectedAnnotationID == nil)
            Button("Run AI on Current Image") { model.runInference() }
                .disabled(model.selectedImage == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                model.inspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
