import Foundation

public struct COCOImporter: Sendable {
    public init() {}

    public func importDataset(at url: URL, imageRoot: URL? = nil) throws -> DatasetImportResult {
        _ = imageRoot
        guard let data = try? Data(contentsOf: url) else { throw DatasetFormatError.unreadableFile(url.path) }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw DatasetFormatError.invalidData(error.localizedDescription) }

        let categories = document.categories.map {
            DatasetCategory(id: StableID.make(namespace: "coco-category", components: [String($0.id), $0.name]), name: $0.name, supercategory: $0.supercategory, sourceID: $0.id)
        }
        let categoryIDs = Dictionary(uniqueKeysWithValues: zip(document.categories, categories).map { ($0.0.id, $0.1.id) })
        let images = document.images.map {
            let relative = $0.fileName.replacingOccurrences(of: "\\", with: "/")
            let split = DatasetSplit(yoloName: $0.split ?? "")
            return DatasetImage(id: StableID.make(namespace: "coco-image", components: [String($0.id), relative]), fileName: URL(fileURLWithPath: relative).lastPathComponent, relativePath: relative, size: .init(width: $0.width, height: $0.height), split: split, sourceID: $0.id)
        }
        let imageIDs = Dictionary(uniqueKeysWithValues: zip(document.images, images).map { ($0.0.id, $0.1.id) })
        let imageSizes = Dictionary(uniqueKeysWithValues: document.images.map { ($0.id, PixelSize(width: $0.width, height: $0.height)) })
        var warnings: [DatasetFormatWarning] = []
        var annotations: [DatasetAnnotation] = []
        for item in document.annotations {
            guard let imageID = imageIDs[item.imageID], let categoryID = categoryIDs[item.categoryID],
                  let size = imageSizes[item.imageID], size.isValid else {
                warnings.append(.init("Skipped annotation referencing a missing image or category"))
                continue
            }
            let geometry: AnnotationGeometry
            if case let .some(.polygons(polygons)) = item.segmentation,
               let polygon = polygons.max(by: { Self.pixelArea($0) < Self.pixelArea($1) }),
               polygon.count >= 6, polygon.count.isMultiple(of: 2) {
                geometry = .polygon(.init(points: stride(from: 0, to: polygon.count, by: 2).map {
                    .init(x: polygon[$0] / Double(size.width), y: polygon[$0 + 1] / Double(size.height))
                }))
                if polygons.count > 1 { warnings.append(.init("Only the largest of multiple COCO polygon segments was imported")) }
            } else if case .some(.rle) = item.segmentation {
                warnings.append(.init("Skipped RLE segmentation; compressed and uncompressed COCO RLE are not supported"))
                continue
            } else if let box = item.bbox, box.count >= 4 {
                geometry = .boundingBox(.init(x: box[0] / Double(size.width), y: box[1] / Double(size.height), width: box[2] / Double(size.width), height: box[3] / Double(size.height)))
            } else {
                warnings.append(.init("Skipped annotation without a supported polygon or bounding box"))
                continue
            }
            let metadata = item.attributes ?? [:]
            annotations.append(.init(id: StableID.make(namespace: "coco-annotation", components: [String(item.id)]), imageID: imageID, categoryID: categoryID, geometry: geometry, attributes: .init(confidence: item.score, isCrowd: item.isCrowd == 1, metadata: metadata), sourceID: item.id))
        }
        let name = url.deletingPathExtension().lastPathComponent
        let info = document.info?.mapValues(\.stringValue) ?? [:]
        return .init(dataset: .init(id: StableID.make(namespace: "coco-dataset", components: [url.standardizedFileURL.path]), name: name, images: images, categories: categories, annotations: annotations, metadata: info.mapKeys { "coco.info.\($0)" }), warnings: warnings)
    }

    private static func pixelArea(_ coordinates: [Double]) -> Double {
        guard coordinates.count >= 6, coordinates.count.isMultiple(of: 2) else { return 0 }
        let points = stride(from: 0, to: coordinates.count, by: 2).map { (coordinates[$0], coordinates[$0 + 1]) }
        return abs(zip(points, points.dropFirst() + points.prefix(1)).reduce(0) { $0 + $1.0.0 * $1.1.1 - $1.1.0 * $1.0.1 }) / 2
    }

    private struct Document: Codable {
        var info: [String: JSONValue]?
        var images: [Image]
        var annotations: [Annotation]
        var categories: [Category]
    }
    private struct Image: Codable { var id: Int; var fileName: String; var width: Int; var height: Int; var split: String?
        enum CodingKeys: String, CodingKey { case id, fileName = "file_name", width, height, split }
    }
    private struct Category: Codable { var id: Int; var name: String; var supercategory: String? }
    private struct Annotation: Codable { var id: Int; var imageID: Int; var categoryID: Int; var bbox: [Double]?; var segmentation: Segmentation?; var isCrowd: Int?; var score: Double?; var attributes: [String: String]?
        enum CodingKeys: String, CodingKey { case id, imageID = "image_id", categoryID = "category_id", bbox, segmentation, isCrowd = "iscrowd", score, attributes }
    }

    private enum Segmentation: Codable {
        case polygons([[Double]])
        case rle

        init(from decoder: Decoder) throws {
            if let polygons = try? [[Double]](from: decoder) { self = .polygons(polygons) }
            else { self = .rle }
        }
        func encode(to encoder: Encoder) throws {
            switch self { case let .polygons(value): try value.encode(to: encoder); case .rle: var container = encoder.singleValueContainer(); try container.encodeNil() }
        }
    }

    private enum JSONValue: Codable {
        case string(String), number(Double), bool(Bool), null
        var stringValue: String {
            switch self { case let .string(value): value; case let .number(value): String(value); case let .bool(value): String(value); case .null: "" }
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported COCO info value") }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self { case let .string(value): try container.encode(value); case let .number(value): try container.encode(value); case let .bool(value): try container.encode(value); case .null: try container.encodeNil() }
        }
    }
}

private extension Dictionary {
    func mapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey) -> [NewKey: Value] {
        Dictionary<NewKey, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
