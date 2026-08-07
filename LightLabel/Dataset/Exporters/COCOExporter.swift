import Foundation

public struct COCOExporter: Sendable {
    public init() {}

    public func export(_ dataset: AnnotationDataset, to url: URL) throws -> DatasetExportResult {
        let categoryIDs = Dictionary(uniqueKeysWithValues: dataset.categories.enumerated().map { ($0.element.id, $0.offset + 1) })
        let imageIDs = Dictionary(uniqueKeysWithValues: dataset.images.enumerated().map { ($0.element.id, $0.offset + 1) })
        var warnings: [DatasetFormatWarning] = []
        let images = dataset.images.map { Image(id: imageIDs[$0.id] ?? 0, fileName: $0.relativePath, width: $0.size.width, height: $0.size.height, split: $0.split == .unassigned ? nil : $0.split.yoloName) }
        let annotations = dataset.annotations.enumerated().compactMap { offset, annotation -> Annotation? in
            guard let imageID = imageIDs[annotation.imageID], let categoryID = categoryIDs[annotation.categoryID], let bounds = annotation.geometry.bounds else { return nil }
            guard let image = dataset.images.first(where: { $0.id == annotation.imageID }), image.size.isValid else { return nil }
            let width = Double(image.size.width)
            let height = Double(image.size.height)
            let segmentation: [[Double]]?
            switch annotation.geometry {
            case let .polygon(polygon): segmentation = [polygon.points.flatMap { [$0.x * width, $0.y * height] }]
            case .boundingBox: segmentation = nil
            }
            if case .polygon = annotation.geometry, segmentation?.first?.count ?? 0 < 6 { warnings.append(.init("Skipped degenerate polygon", file: dataset.images.first { $0.id == annotation.imageID }?.fileName)); return nil }
            let pixelArea: Double
            switch annotation.geometry { case let .polygon(polygon): pixelArea = polygon.area * width * height; case .boundingBox: pixelArea = bounds.area * width * height }
            return Annotation(id: annotation.sourceID ?? (offset + 1), imageID: imageID, categoryID: categoryID, bbox: [bounds.x * width, bounds.y * height, bounds.width * width, bounds.height * height], area: pixelArea, segmentation: segmentation, isCrowd: annotation.attributes.isCrowd ? 1 : 0, score: annotation.attributes.confidence, attributes: annotation.attributes.metadata)
        }
        let document = Document(info: ["description": dataset.name], images: images, annotations: annotations, categories: dataset.categories.enumerated().map { Category(id: categoryIDs[$0.element.id] ?? $0.offset + 1, name: $0.element.name, supercategory: $0.element.supercategory) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
        return .init(filesWritten: 1, warnings: warnings)
    }

    private struct Document: Codable { var info: [String: String]; var images: [Image]; var annotations: [Annotation]; var categories: [Category] }
    private struct Image: Codable { var id: Int; var fileName: String; var width: Int; var height: Int; var split: String?
        enum CodingKeys: String, CodingKey { case id, fileName = "file_name", width, height, split }
    }
    private struct Category: Codable { var id: Int; var name: String; var supercategory: String? }
    private struct Annotation: Codable { var id: Int; var imageID: Int; var categoryID: Int; var bbox: [Double]; var area: Double; var segmentation: [[Double]]?; var isCrowd: Int; var score: Double?; var attributes: [String: String]
        enum CodingKeys: String, CodingKey { case id, imageID = "image_id", categoryID = "category_id", bbox, area, segmentation, isCrowd = "iscrowd", score, attributes }
    }
}
