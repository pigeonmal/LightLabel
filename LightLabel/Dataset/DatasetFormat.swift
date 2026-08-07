import Foundation

public enum DatasetSyncFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case yoloDetection
    case yoloSegmentation
    case coco

    public var id: Self { self }

    public var title: String {
        switch self {
        case .yoloDetection: "YOLO Detection"
        case .yoloSegmentation: "YOLO Segmentation"
        case .coco: "COCO JSON"
        }
    }

    public var storageFormat: String {
        switch self {
        case .yoloDetection, .yoloSegmentation: "yolo"
        case .coco: "coco"
        }
    }

    public var yoloTask: YOLOTask? {
        switch self {
        case .yoloDetection: .detection
        case .yoloSegmentation: .segmentation
        case .coco: nil
        }
    }
}

public struct DatasetFormatWarning: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(file ?? ""):\(line.map(String.init) ?? ""):\(message)" }
    public let message: String
    public let file: String?
    public let line: Int?

    public init(_ message: String, file: String? = nil, line: Int? = nil) {
        self.message = message
        self.file = file
        self.line = line
    }
}

public struct DatasetImportResult: Sendable {
    public let dataset: AnnotationDataset
    public let warnings: [DatasetFormatWarning]

    public init(dataset: AnnotationDataset, warnings: [DatasetFormatWarning] = []) {
        self.dataset = dataset
        self.warnings = warnings
    }
}

public struct DatasetExportResult: Sendable {
    public let filesWritten: Int
    public let warnings: [DatasetFormatWarning]

    public init(filesWritten: Int, warnings: [DatasetFormatWarning] = []) {
        self.filesWritten = filesWritten
        self.warnings = warnings
    }
}

public enum DatasetFormatError: LocalizedError, Sendable {
    case unreadableFile(String)
    case invalidData(String)
    case missingCategories
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(path): "Could not read \(path)."
        case let .invalidData(reason): "Invalid dataset data: \(reason)"
        case .missingCategories: "The dataset contains no categories."
        case let .unsupported(reason): "Unsupported dataset content: \(reason)"
        }
    }
}
