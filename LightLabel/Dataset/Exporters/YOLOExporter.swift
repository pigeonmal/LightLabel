import Foundation

public struct YOLOExporter: Sendable {
    public init() {}

    public func export(_ dataset: AnnotationDataset, to rootURL: URL, task: YOLOTask) throws -> DatasetExportResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let categories = dataset.categories.enumerated().reduce(into: [UUID: Int]()) { $0[$1.element.id] = $1.offset }
        var warnings: [DatasetFormatWarning] = []
        var filesWritten = 0
        let grouped = Dictionary(grouping: dataset.annotations, by: \.imageID)

        let labelsRoot = rootURL.appendingPathComponent("labels")
        if let splitDirectories = try? fileManager.contentsOfDirectory(at: labelsRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for directory in splitDirectories {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if let existing = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    for file in existing where file.pathExtension.lowercased() == "txt" {
                        try fileManager.removeItem(at: file)
                    }
                }
            }
        }

        for image in dataset.images {
            let split = image.split == .unassigned ? DatasetSplit.train : image.split
            let labelDirectory = rootURL.appendingPathComponent("labels/\(split.yoloName)")
            try fileManager.createDirectory(at: labelDirectory, withIntermediateDirectories: true)
            let labelURL = labelDirectory.appendingPathComponent(URL(fileURLWithPath: image.fileName).deletingPathExtension().lastPathComponent).appendingPathExtension("txt")
            var lines: [String] = []
            for annotation in grouped[image.id, default: []] {
                guard let classIndex = categories[annotation.categoryID] else {
                    warnings.append(.init("Skipped annotation with unknown category", file: image.fileName))
                    continue
                }
                switch (task, annotation.geometry) {
                case (.detection, let geometry):
                    guard let box = geometry.bounds else { continue }
                    lines.append(([Double(classIndex), box.center.x, box.center.y, box.width, box.height]).map(format).joined(separator: " "))
                case (.segmentation, let .polygon(polygon)):
                    lines.append(([String(classIndex)] + polygon.points.flatMap { [format($0.x), format($0.y)] }).joined(separator: " "))
                case (.segmentation, .boundingBox):
                    warnings.append(.init("Skipped bounding box in segmentation export", file: image.fileName))
                case (.automatic, let .polygon(polygon)):
                    lines.append(([String(classIndex)] + polygon.points.flatMap { [format($0.x), format($0.y)] }).joined(separator: " "))
                case (.automatic, let .boundingBox(box)):
                    lines.append(([Double(classIndex), box.center.x, box.center.y, box.width, box.height]).map(format).joined(separator: " "))
                }
            }
            try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: labelURL, atomically: true, encoding: .utf8)
            filesWritten += 1
        }
        let escapedNames = dataset.categories.map { "'\($0.name.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
        let yaml = "path: .\ntrain: images/train\nval: images/val\ntest: images/test\nnames: [\(escapedNames)]\n"
        try yaml.write(to: rootURL.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
        return .init(filesWritten: filesWritten + 1, warnings: warnings)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
