import Foundation

public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var isValid: Bool { width > 0 && height > 0 }
}

public enum DatasetSplit: String, Codable, CaseIterable, Sendable {
    case train
    case validation
    case test
    case unassigned

    public init(yoloName: String) {
        switch yoloName.lowercased() {
        case "train": self = .train
        case "val", "valid", "validation": self = .validation
        case "test": self = .test
        default: self = .unassigned
        }
    }

    public var yoloName: String {
        self == .validation ? "val" : rawValue
    }
}

public struct AnnotationAttributes: Codable, Hashable, Sendable {
    public var confidence: Double?
    public var isCrowd: Bool
    public var isDifficult: Bool
    public var metadata: [String: String]

    public init(
        confidence: Double? = nil,
        isCrowd: Bool = false,
        isDifficult: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.confidence = confidence
        self.isCrowd = isCrowd
        self.isDifficult = isDifficult
        self.metadata = metadata
    }
}

public enum AnnotationSource: String, Codable, CaseIterable, Sendable {
    case manual
    case aiSuggestion
    case aiAccepted
}

public enum ReviewState: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case reviewed
    case needsAttention
}

public struct DatasetCategory: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var supercategory: String?
    public var sourceID: Int?
    public var metadata: [String: String]
    public var colorHex: String

    public init(
        id: UUID = UUID(),
        name: String,
        supercategory: String? = nil,
        sourceID: Int? = nil,
        metadata: [String: String] = [:],
        colorHex: String = "#4F8EF7"
    ) {
        self.id = id
        self.name = name
        self.supercategory = supercategory
        self.sourceID = sourceID
        self.metadata = metadata
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey { case id, name, supercategory, sourceID, metadata, colorHex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        supercategory = try container.decodeIfPresent(String.self, forKey: .supercategory)
        sourceID = try container.decodeIfPresent(Int.self, forKey: .sourceID)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#4F8EF7"
    }
}

public struct DatasetImage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var fileName: String
    /// Path relative to the project root when possible.
    public var relativePath: String
    public var size: PixelSize
    public var split: DatasetSplit
    public var sourceID: Int?
    public var metadata: [String: String]
    public var reviewState: ReviewState

    public init(
        id: UUID = UUID(),
        fileName: String,
        relativePath: String? = nil,
        size: PixelSize,
        split: DatasetSplit = .unassigned,
        sourceID: Int? = nil,
        metadata: [String: String] = [:],
        reviewState: ReviewState = .unreviewed
    ) {
        self.id = id
        self.fileName = fileName
        self.relativePath = relativePath ?? fileName
        self.size = size
        self.split = split
        self.sourceID = sourceID
        self.metadata = metadata
        self.reviewState = reviewState
    }

    private enum CodingKeys: String, CodingKey { case id, fileName, relativePath, size, split, sourceID, metadata, reviewState }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? fileName
        size = try container.decode(PixelSize.self, forKey: .size)
        split = try container.decodeIfPresent(DatasetSplit.self, forKey: .split) ?? .unassigned
        sourceID = try container.decodeIfPresent(Int.self, forKey: .sourceID)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        reviewState = try container.decodeIfPresent(ReviewState.self, forKey: .reviewState) ?? .unreviewed
    }
}

public struct DatasetAnnotation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var imageID: UUID
    public var categoryID: UUID
    public var geometry: AnnotationGeometry
    public var attributes: AnnotationAttributes
    public var sourceID: Int?
    public var source: AnnotationSource
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        imageID: UUID,
        categoryID: UUID,
        geometry: AnnotationGeometry,
        attributes: AnnotationAttributes = .init(),
        sourceID: Int? = nil,
        source: AnnotationSource = .manual,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.imageID = imageID
        self.categoryID = categoryID
        self.geometry = geometry
        self.attributes = attributes
        self.sourceID = sourceID
        self.source = source
        self.isVisible = isVisible
        self.isLocked = isLocked
    }

    private enum CodingKeys: String, CodingKey { case id, imageID, categoryID, geometry, attributes, sourceID, source, isVisible, isLocked }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        imageID = try container.decode(UUID.self, forKey: .imageID)
        categoryID = try container.decode(UUID.self, forKey: .categoryID)
        geometry = try container.decode(AnnotationGeometry.self, forKey: .geometry)
        attributes = try container.decodeIfPresent(AnnotationAttributes.self, forKey: .attributes) ?? .init()
        sourceID = try container.decodeIfPresent(Int.self, forKey: .sourceID)
        source = try container.decodeIfPresent(AnnotationSource.self, forKey: .source) ?? .manual
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

public struct AnnotationDataset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var images: [DatasetImage]
    public var categories: [DatasetCategory]
    public var annotations: [DatasetAnnotation]
    public var metadata: [String: String]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        images: [DatasetImage] = [],
        categories: [DatasetCategory] = [],
        annotations: [DatasetAnnotation] = [],
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.images = images
        self.categories = categories
        self.annotations = annotations
        self.metadata = metadata
        self.createdAt = Self.wholeSecond(createdAt)
        self.modifiedAt = Self.wholeSecond(modifiedAt)
    }

    public func annotations(for imageID: UUID) -> [DatasetAnnotation] {
        annotations.filter { $0.imageID == imageID }
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
