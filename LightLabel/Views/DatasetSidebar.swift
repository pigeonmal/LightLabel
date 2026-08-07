import AppKit
import SwiftUI

struct DatasetSidebar: View {
    @Bindable var model: AppModel
    @State private var categoryEditor: CategoryEditor?
    @State private var tagEditor: TagEditor?
    @State private var showSmartSplit = false

    var body: some View {
        VStack(spacing: 0) {
            if let dataset = model.dataset {
                List {
                    Section {
                        TextField("Search filenames, classes, and tags", text: $model.searchText)
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

                    Section {
                        Button {
                            model.clearTagFilter()
                        } label: {
                            HStack {
                                Label("All tags", systemImage: "tag")
                                Spacer()
                                if model.tagFilterID == nil { Image(systemName: "checkmark") }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if dataset.tags.isEmpty {
                            Text("No tags yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(dataset.tags) { tag in
                                Button {
                                    model.tagFilterID = tag.id
                                } label: {
                                    HStack {
                                        Circle().fill(Color(hex: tag.colorHex)).frame(width: 10, height: 10)
                                        Text(tag.name).lineLimit(1)
                                        Spacer()
                                        Text(model.tagCount(tag.id), format: .number)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                        if model.tagFilterID == tag.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Edit…") { tagEditor = .init(tagID: tag.id, name: tag.name, color: Color(hex: tag.colorHex)) }
                                    Divider()
                                    Button("Delete Tag", role: .destructive) { model.deleteTag(id: tag.id) }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Tags")
                            Spacer()
                            if model.tagFilterID != nil {
                                Button { model.clearTagFilter() } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Clear tag filter")
                            }
                            Button { tagEditor = .init(tagID: nil, name: "New Tag", color: Color.gray) } label: { Image(systemName: "plus") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Add tag")
                        }
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

                    Section {
                        ForEach(dataset.categories, id: \.id) { category in
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: category.colorHex)).frame(width: 10, height: 10)
                                Text(category.name).lineLimit(1)
                                Spacer()
                                let isIncluded = model.includedCategoryIDs.contains(category.id)
                                let isExcluded = model.excludedCategoryIDs.contains(category.id)
                                Image(systemName: isIncluded ? "checkmark.circle.fill" : "checkmark.circle")
                                    .foregroundStyle(isIncluded ? .green : .secondary)
                                    .onTapGesture { model.toggleIncludeCategory(category.id) }
                                    .help("Include only this class")
                                Image(systemName: isExcluded ? "minus.circle.fill" : "minus.circle")
                                    .foregroundStyle(isExcluded ? .red : .secondary)
                                    .onTapGesture { model.toggleExcludeCategory(category.id) }
                                    .help("Exclude this class")
                            }
                            .contentShape(Rectangle())
                        }
                    } header: {
                        HStack {
                            Text("Filter by Class")
                            Spacer()
                            if !model.includedCategoryIDs.isEmpty || !model.excludedCategoryIDs.isEmpty {
                                Button { model.clearCategoryFilters() } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Clear class filter")
                            }
                        }
                    }

                    Section("Statistics") {
                        LabeledContent("Images", value: dataset.images.count.formatted())
                        LabeledContent("Annotations", value: dataset.annotations.count.formatted())
                        LabeledContent("Showing", value: model.filteredImageCount.formatted())
                    }

                    Section("Dataset") {
                        Button("Smart Split…", systemImage: "wand.and.stars") { showSmartSplit = true }
                        if model.selectedImageIDs.count > 1 {
                            Text("\(model.selectedImageIDs.count) images selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                            Button("Import Into Current Dataset…", action: model.importIntoCurrentDataset)
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
        .sheet(item: $tagEditor) { editor in
            TagEditorSheet(editor: editor) { name, color in
                let hex = color.hexString
                if let id = editor.tagID { model.updateTag(id: id, name: name, colorHex: hex) }
                else { model.addTag(name: name, colorHex: hex) }
            }
        }
        .sheet(isPresented: $showSmartSplit) {
            SmartSplitSheet(model: model)
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
        case .suggestions: "sparkles"
        }
    }
}

private struct SmartSplitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var trainRatio = 0.8
    @State private var validationRatio = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Smart Split").font(.title2.weight(.semibold))
            Text("Images are grouped by visual similarity, then assigned to preserve class ratios.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                HStack {
                    Text("Train")
                    Spacer()
                    Text("\(Int(trainRatio * 100))%")
                }
                Slider(value: $trainRatio, in: 0.5...0.95, step: 0.05)
                HStack {
                    Text("Validation")
                    Spacer()
                    Text("\(Int(validationRatio * 100))%")
                }
                Slider(value: $validationRatio, in: 0...min(0.4, 1 - trainRatio), step: 0.05)
                Text("Test: \(Int(max(0, 1 - trainRatio - validationRatio) * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Split") {
                    model.smartSplit(trainRatio: trainRatio, validationRatio: validationRatio)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

private struct CategoryEditor: Identifiable {
    let id = UUID()
    var categoryID: UUID?
    var name: String
    var color: Color
}

struct TagEditor: Identifiable {
    let id = UUID()
    var tagID: UUID?
    var name: String
    var color: Color
}

struct TagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: TagEditor
    let save: (String, Color) -> Void
    @State private var name: String
    @State private var color: Color

    init(editor: TagEditor, save: @escaping (String, Color) -> Void) {
        self.editor = editor
        self.save = save
        _name = State(initialValue: editor.name)
        _color = State(initialValue: editor.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editor.tagID == nil ? "Add Tag" : "Edit Tag")
                .font(.title2.weight(.semibold))
            TextField("Tag name", text: $name)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(name, color); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
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
