import AppKit
import SwiftUI

struct DatasetSidebar: View {
    @Bindable var model: AppModel
    @State private var categoryEditor: CategoryEditor?

    var body: some View {
        VStack(spacing: 0) {
            if let dataset = model.dataset {
                List {
                    Section {
                        TextField("Search filenames and classes", text: $model.searchText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search dataset")
                    }

                    Section("Split") {
                        Picker("Split", selection: $model.splitFilter) {
                            ForEach(SplitFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    Section("Status") {
                        ForEach(StatusFilter.allCases) { status in
                            Button {
                                model.statusFilter = status
                            } label: {
                                HStack {
                                    Label(status.rawValue, systemImage: statusSymbol(status))
                                    Spacer()
                                    if model.statusFilter == status { Image(systemName: "checkmark") }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Section {
                        ForEach(dataset.categories, id: \.id) { category in
                            Button { model.selectedCategoryID = category.id } label: {
                                HStack {
                                    Circle().fill(Color(hex: category.colorHex)).frame(width: 10, height: 10)
                                    Text(category.name).lineLimit(1)
                                    Spacer()
                                    Text(categoryCount(category.id), format: .number)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    if model.selectedCategoryID == category.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit…") { categoryEditor = .init(categoryID: category.id, name: category.name, color: Color(hex: category.colorHex)) }
                                Divider()
                                Button("Delete Class", role: .destructive) { model.deleteCategory(id: category.id) }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Classes")
                            Spacer()
                            Button { categoryEditor = .init(categoryID: nil, name: "New Class", color: .blue) } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add class")
                        }
                    }

                    Section("Statistics") {
                        LabeledContent("Images", value: dataset.images.count.formatted())
                        LabeledContent("Annotations", value: dataset.annotations.count.formatted())
                        LabeledContent("Showing", value: model.filteredImages.count.formatted())
                    }

                    Section("Validation") {
                        Label(model.validation.message, systemImage: validationSymbol)
                            .foregroundStyle(model.validation.errors > 0 ? .red : .secondary)
                            .font(.caption)
                        Button("Validate Dataset", action: model.validate)
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dataset.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Text(dataset.rootURL?.path(percentEncoded: false) ?? "Unsaved dataset")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 10)
                    .background(.bar)
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button { model.addImages() } label: { Label("Add", systemImage: "plus") }
                        Spacer()
                        Menu {
                            Button("Import YOLO or COCO…", action: model.importDataset)
                            Button("Export Dataset…", action: model.exportDataset)
                        } label: {
                            Label("Transfer", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal).padding(.vertical, 9)
                    .background(.bar)
                }
            } else {
                List {
                    Button("New Dataset…", action: model.createDataset)
                    Button("Open Dataset…", action: model.openDataset)
                    Button("Import Dataset…", action: model.importDataset)
                }
                .listStyle(.sidebar)
                .navigationTitle("LightLabel")
            }
        }
        .sheet(item: $categoryEditor) { editor in
            CategoryEditorSheet(editor: editor) { name, color in
                let hex = color.hexString
                if let id = editor.categoryID { model.updateCategory(id: id, name: name, colorHex: hex) } else { model.addCategory(name: name, colorHex: hex) }
            }
        }
    }

    private func categoryCount(_ id: UUID) -> Int {
        model.annotationCount(forCategoryID: id)
    }

    private func statusSymbol(_ status: StatusFilter) -> String {
        switch status {
        case .all: "photo.on.rectangle.angled"
        case .unannotated: "circle.dashed"
        case .annotated: "rectangle.and.pencil.and.ellipsis"
        case .reviewed: "checkmark.seal"
        case .suggestions: "sparkles"
        }
    }

    private var validationSymbol: String {
        if model.validation.errors > 0 { return "xmark.octagon.fill" }
        if model.validation.warnings > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle"
    }
}

private struct CategoryEditor: Identifiable {
    let id = UUID()
    var categoryID: UUID?
    var name: String
    var color: Color
}

private struct CategoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: CategoryEditor
    let save: (String, Color) -> Void
    @State private var name: String
    @State private var color: Color

    init(editor: CategoryEditor, save: @escaping (String, Color) -> Void) {
        self.editor = editor; self.save = save; _name = State(initialValue: editor.name); _color = State(initialValue: editor.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editor.categoryID == nil ? "Add Class" : "Edit Class").font(.title2.weight(.semibold))
            TextField("Class name", text: $name)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(name, color); dismiss() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 360)
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let red, green, blue: Double
        if value.count == 3 {
            red = Double((number >> 8) * 17) / 255
            green = Double((number >> 4 & 0xF) * 17) / 255
            blue = Double((number & 0xF) * 17) / 255
        } else {
            red = Double(number >> 16 & 0xFF) / 255
            green = Double(number >> 8 & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
        }
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#4F8EF7" }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
