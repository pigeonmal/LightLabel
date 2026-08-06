import Foundation

public enum ValidationSeverity: String, Codable, Sendable { case warning, error }

public struct DatasetValidationIssue: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let severity: ValidationSeverity
    public let message: String
    public let imageID: UUID?
    public let annotationID: UUID?

    public init(severity: ValidationSeverity, message: String, imageID: UUID? = nil, annotationID: UUID? = nil) {
        self.id = [imageID?.uuidString, annotationID?.uuidString, severity.rawValue, message].compactMap { $0 }.joined(separator: ":")
        self.severity = severity; self.message = message; self.imageID = imageID; self.annotationID = annotationID
    }
}

public struct DatasetValidator: Sendable {
    public var minimumPolygonArea: Double
    public init(minimumPolygonArea: Double = 1e-8) { self.minimumPolygonArea = minimumPolygonArea }

    public func validate(_ dataset: AnnotationDataset) -> [DatasetValidationIssue] {
        let imageIDs = Set(dataset.images.map(\.id))
        let categoryIDs = Set(dataset.categories.map(\.id))
        var issues: [DatasetValidationIssue] = []
        if dataset.categories.isEmpty { issues.append(.init(severity: .error, message: "Dataset has no categories.")) }
        if Set(dataset.categories.map { $0.name.lowercased() }).count != dataset.categories.count { issues.append(.init(severity: .warning, message: "Category names are not unique.")) }
        for image in dataset.images {
            if !image.size.isValid { issues.append(.init(severity: .error, message: "Image dimensions are invalid.", imageID: image.id)) }
            if let root = dataset.metadata["lightlabel.rootURL"] {
                let url = URL(fileURLWithPath: root).appendingPathComponent(image.relativePath)
                if !FileManager.default.fileExists(atPath: url.path) {
                    issues.append(.init(severity: .error, message: "Image file is missing: \(image.relativePath).", imageID: image.id))
                }
            }
        }
        let duplicatePaths = Dictionary(grouping: dataset.images, by: \.relativePath).values.filter { $0.count > 1 }
        for duplicates in duplicatePaths {
            for image in duplicates {
                issues.append(.init(severity: .error, message: "Duplicate image record: \(image.relativePath).", imageID: image.id))
            }
        }
        for annotation in dataset.annotations {
            if !imageIDs.contains(annotation.imageID) { issues.append(.init(severity: .error, message: "Annotation references a missing image.", annotationID: annotation.id)) }
            if !categoryIDs.contains(annotation.categoryID) { issues.append(.init(severity: .error, message: "Annotation references a missing category.", annotationID: annotation.id)) }
            switch annotation.geometry {
            case let .boundingBox(box):
                if !box.isNormalized || !box.isValid { issues.append(.init(severity: .error, message: "Bounding box is outside normalized bounds or has no area.", annotationID: annotation.id)) }
            case let .polygon(polygon):
                if !polygon.isValid { issues.append(.init(severity: .error, message: "Polygon is invalid: \(polygon.validationIssues.map(\.rawValue).joined(separator: ", ")).", annotationID: annotation.id)) }
                else if polygon.area < minimumPolygonArea { issues.append(.init(severity: .warning, message: "Polygon area is very small.", annotationID: annotation.id)) }
            }
        }
        return issues
    }
}
