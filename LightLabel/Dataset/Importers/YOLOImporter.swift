import Foundation
import ImageIO

public enum YOLOTask: String, Codable, Sendable {
    case detection
    case segmentation
    case automatic
}

public struct YOLODataConfiguration: Hashable, Sendable {
    public var names: [String]
    public var paths: [DatasetSplit: String]

    public init(names: [String], paths: [DatasetSplit: String] = [:]) {
        self.names = names
        self.paths = paths
    }

    public static func parse(_ text: String) throws -> Self {
        let lines = text.components(separatedBy: .newlines)
        var paths: [DatasetSplit: String] = [:]
        var indexedNames: [Int: String] = [:]
        var listNames: [String] = []
        var inNamesBlock = false

        for rawLine in lines {
            let indentation = rawLine.prefix { $0 == " " || $0 == "\t" }.count
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }

            if inNamesBlock && indentation > 0, let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let index = Int(key) { indexedNames[index] = unquote(value) }
                continue
            }
            inNamesBlock = false
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "names" {
                if value.isEmpty {
                    inNamesBlock = true
                } else if value.first == "[", value.last == "]" {
                    listNames = value.dropFirst().dropLast().split(separator: ",").map {
                        unquote($0.trimmingCharacters(in: .whitespaces))
                    }
                }
            } else {
                let split = DatasetSplit(yoloName: key)
                if split != .unassigned { paths[split] = unquote(value) }
            }
        }
        let names = listNames.isEmpty ? indexedNames.sorted { $0.key < $1.key }.map(\.value) : listNames
        guard !names.isEmpty else { throw DatasetFormatError.invalidData("data.yaml has no parseable names") }
        return .init(names: names, paths: paths)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        return String(value.dropFirst().dropLast())
    }
}

public struct YOLOImporter: Sendable {
    public init() {}

    public func importDataset(at rootURL: URL, task: YOLOTask = .automatic) throws -> DatasetImportResult {
        let fileManager = FileManager.default
        let yamlURL = ["data.yaml", "dataset.yaml"].map { rootURL.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
        guard let yamlURL, let yaml = try? String(contentsOf: yamlURL, encoding: .utf8) else {
            throw DatasetFormatError.unreadableFile("data.yaml")
        }
        let configuration = try YOLODataConfiguration.parse(yaml)
        let categories = configuration.names.enumerated().map { index, name in
            DatasetCategory(
                id: StableID.make(namespace: "yolo-category", components: [String(index), name]),
                name: name,
                sourceID: index
            )
        }
        var images: [DatasetImage] = []
        var annotations: [DatasetAnnotation] = []
        var warnings: [DatasetFormatWarning] = []

        for split in [DatasetSplit.train, .validation, .test, .unassigned] {
            let imageDirectory = resolveImageDirectory(root: rootURL, configuredPath: configuration.paths[split], split: split)
            guard let imageDirectory, fileManager.fileExists(atPath: imageDirectory.path) else { continue }
            let files = (try? fileManager.contentsOfDirectory(
                at: imageDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for imageURL in files.filter({ Self.imageExtensions.contains($0.pathExtension.lowercased()) }).sorted(by: { $0.path < $1.path }) {
                guard let size = Self.imageSize(at: imageURL) else {
                    warnings.append(.init("Could not read image dimensions", file: imageURL.path))
                    continue
                }
                let relativePath = imageURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                let imageID = StableID.make(namespace: "yolo-image", components: [relativePath])
                images.append(.init(id: imageID, fileName: imageURL.lastPathComponent, relativePath: relativePath, size: size, split: split))
                let labelURL = resolveLabelURL(for: imageURL, root: rootURL, split: split)
                guard fileManager.fileExists(atPath: labelURL.path) else { continue }
                let parsed = try parseLabels(at: labelURL, imageID: imageID, categories: categories, task: task)
                annotations.append(contentsOf: parsed.annotations)
                warnings.append(contentsOf: parsed.warnings)
            }
        }
        let name = rootURL.lastPathComponent.isEmpty ? "YOLO Dataset" : rootURL.lastPathComponent
        let datasetID = StableID.make(namespace: "yolo-dataset", components: [rootURL.standardizedFileURL.path])
        return .init(dataset: .init(id: datasetID, name: name, images: images, categories: categories, annotations: annotations), warnings: warnings)
    }

    private func parseLabels(
        at url: URL,
        imageID: UUID,
        categories: [DatasetCategory],
        task: YOLOTask
    ) throws -> (annotations: [DatasetAnnotation], warnings: [DatasetFormatWarning]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw DatasetFormatError.unreadableFile(url.path)
        }
        var output: [DatasetAnnotation] = []
        var warnings: [DatasetFormatWarning] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let values = rawLine.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            guard !values.isEmpty else { continue }
            let line = offset + 1
            guard values.count == rawLine.split(whereSeparator: \.isWhitespace).count,
                  let classIndex = Int(exactly: values[0]), categories.indices.contains(classIndex) else {
                warnings.append(.init("Invalid class or numeric value", file: url.path, line: line))
                continue
            }
            let geometry: AnnotationGeometry?
            if (task == .segmentation || task == .automatic && values.count > 5), values.count >= 7, values.count % 2 == 1 {
                let points = stride(from: 1, to: values.count, by: 2).map { NormalizedPoint(x: values[$0], y: values[$0 + 1]) }
                geometry = .polygon(.init(points: points))
            } else if task != .segmentation, values.count == 5 {
                geometry = .boundingBox(.init(centerX: values[1], centerY: values[2], width: values[3], height: values[4]))
            } else {
                geometry = nil
            }
            guard let geometry else {
                warnings.append(.init("Label does not match the selected YOLO task", file: url.path, line: line))
                continue
            }
            let annotationID = StableID.make(namespace: "yolo-annotation", components: [url.path, String(line), rawLine])
            output.append(.init(id: annotationID, imageID: imageID, categoryID: categories[classIndex].id, geometry: geometry))
        }
        return (output, warnings)
    }

    private func resolveImageDirectory(root: URL, configuredPath: String?, split: DatasetSplit) -> URL? {
        if let configuredPath, !configuredPath.isEmpty {
            let path = configuredPath.replacingOccurrences(of: "\\", with: "/")
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        }
        if split == .unassigned { return root.appendingPathComponent("images") }
        let candidates = [root.appendingPathComponent("images/\(split.yoloName)"), root.appendingPathComponent(split.yoloName + "/images")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func resolveLabelURL(for image: URL, root: URL, split: DatasetSplit) -> URL {
        let path = image.path
        let labelPath: String
        if path.contains("/images/") {
            labelPath = path.replacingOccurrences(of: "/images/", with: "/labels/")
        } else if path.contains("/images") {
            labelPath = path.replacingOccurrences(of: "/images", with: "/labels")
        } else {
            let directory = split == .unassigned ? root.appendingPathComponent("labels") : root.appendingPathComponent("labels/\(split.yoloName)")
            return directory.appendingPathComponent(image.deletingPathExtension().lastPathComponent).appendingPathExtension("txt")
        }
        return URL(fileURLWithPath: labelPath).deletingPathExtension().appendingPathExtension("txt")
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "webp"]
    private static func imageSize(at url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return .init(width: width, height: height)
    }
}
