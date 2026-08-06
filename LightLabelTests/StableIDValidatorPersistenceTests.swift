import Foundation
import XCTest

@testable import LightLabel

final class StableIDValidatorPersistenceTests: XCTestCase {
    func testStableIDIsDeterministicNamespacedAndRFC4122Shaped() {
        let first = StableID.make(namespace: "image", components: ["train", "a.png"])
        let repeated = StableID.make(namespace: "image", components: ["train", "a.png"])
        let reordered = StableID.make(namespace: "image", components: ["a.png", "train"])
        let otherNamespace = StableID.make(namespace: "annotation", components: ["train", "a.png"])

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, reordered)
        XCTAssertNotEqual(first, otherNamespace)
        XCTAssertEqual(first.uuidString[first.uuidString.index(first.uuidString.startIndex, offsetBy: 14)], "5")
    }

    func testValidatorReportsDatasetAndGeometryFailures() {
        let image = DatasetImage(fileName: "bad.png", size: .init(width: 0, height: 10))
        let category = DatasetCategory(name: "Object")
        let duplicate = DatasetCategory(name: "object")
        let invalidBox = DatasetAnnotation(
            imageID: image.id,
            categoryID: category.id,
            geometry: .boundingBox(.init(x: 0.9, y: 0.9, width: 0.2, height: 0.2))
        )
        let missingReferences = DatasetAnnotation(
            imageID: UUID(),
            categoryID: UUID(),
            geometry: .polygon(.init(points: [.init(x: 0, y: 0), .init(x: 1, y: 0)]))
        )
        let dataset = AnnotationDataset(
            name: "Invalid",
            images: [image],
            categories: [category, duplicate],
            annotations: [invalidBox, missingReferences]
        )

        let issues = DatasetValidator().validate(dataset)

        XCTAssertEqual(issues.filter { $0.severity == .warning }.count, 1)
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, 5)
        XCTAssertTrue(issues.contains { $0.message.contains("not unique") })
        XCTAssertTrue(issues.contains { $0.message.contains("dimensions") && $0.imageID == image.id })
        XCTAssertTrue(issues.contains { $0.message.contains("missing image") })
        XCTAssertTrue(issues.contains { $0.message.contains("missing category") })
        XCTAssertTrue(issues.contains { $0.message.contains("Bounding box") && $0.annotationID == invalidBox.id })
        XCTAssertTrue(issues.contains { $0.message.contains("Polygon is invalid") })
    }

    func testSmallValidPolygonProducesWarningAtConfiguredThreshold() {
        let image = DatasetImage(fileName: "image.png", size: .init(width: 10, height: 10))
        let category = DatasetCategory(name: "object")
        let polygon = Polygon(points: [
            .init(x: 0, y: 0), .init(x: 0.001, y: 0), .init(x: 0, y: 0.001)
        ])
        let dataset = AnnotationDataset(
            name: "Small",
            images: [image],
            categories: [category],
            annotations: [.init(imageID: image.id, categoryID: category.id, geometry: .polygon(polygon))]
        )

        let issues = DatasetValidator(minimumPolygonArea: 0.001).validate(dataset)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.severity, .warning)
        XCTAssertTrue(issues.first?.message.contains("very small") == true)
    }

    func testProjectPersistenceSerializesAndLoadsDataset() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let image = DatasetImage(fileName: "image.png", size: .init(width: 20, height: 10), split: .test)
        let category = DatasetCategory(name: "object", sourceID: 4)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let dataset = AnnotationDataset(
            name: "Persisted",
            images: [image],
            categories: [category],
            annotations: [.init(imageID: image.id, categoryID: category.id, geometry: .boundingBox(.init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))],
            metadata: ["owner": "local"],
            createdAt: created,
            modifiedAt: created
        )
        let persistence = ProjectPersistence(directoryURL: directory)

        try await persistence.save(dataset)
        let loaded = try await persistence.loadDataset()
        let json = try String(contentsOf: directory.appendingPathComponent("dataset.json"), encoding: .utf8)

        XCTAssertEqual(loaded, dataset)
        XCTAssertTrue(json.contains("\"type\" : \"boundingBox\""))
        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"))
    }

    func testScheduledSavePersistsLatestSnapshot() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let persistence = ProjectPersistence(directoryURL: directory)

        await persistence.scheduleSave(.init(name: "First"), after: .milliseconds(100))
        await persistence.scheduleSave(.init(name: "Latest"), after: .milliseconds(10))
        try await persistence.flushScheduledSave()

        let loaded = try await persistence.loadDataset()
        XCTAssertEqual(loaded.name, "Latest")
    }
}
