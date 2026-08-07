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

    func testLegacyDatasetWithoutTagsDecodesWithEmptyTags() throws {
        let id = UUID()
        let data = try XCTUnwrap("{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy\"}".data(using: .utf8))
        let decoded = try JSONDecoder().decode(AnnotationDataset.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertTrue(decoded.tags.isEmpty)
        XCTAssertTrue(decoded.images.isEmpty)
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

    func testSmartSplitAssignsEveryImageAndKeepsClassDistribution() {
        let category = DatasetCategory(name: "bird")
        let images = (0..<10).map { DatasetImage(fileName: "\($0).png", size: .init(width: 10, height: 10)) }
        let annotations = images.map { DatasetAnnotation(imageID: $0.id, categoryID: category.id, geometry: .boundingBox(.init(x: 0, y: 0, width: 0.2, height: 0.2))) }
        let assignments = SmartSplitPlanner().assignments(
            images: images,
            annotations: annotations,
            configuration: .init(trainRatio: 0.8, validationRatio: 0.1)
        )

        XCTAssertEqual(assignments.count, images.count)
        XCTAssertEqual(Set(assignments.values), Set([.train, .validation, .test]))
        XCTAssertEqual(assignments.values.count(where: { $0 == .train }), 8)
        XCTAssertEqual(assignments.values.count(where: { $0 == .validation }), 1)
        XCTAssertEqual(assignments.values.count(where: { $0 == .test }), 1)
    }

    func testCancellableMergeSortOrdersLargeLabelSnapshotWithoutMainActorWork() async throws {
        let snapshots = (0..<20_000).reversed().map { offset in
            ImageBrowserSnapshot(
                image: DatasetImage(
                    id: StableID.make(namespace: "performance-image", components: [String(offset)]),
                    fileName: "image-(offset).png",
                    size: .init(width: 640, height: 640)
                ),
                labelCount: offset % 23
            )
        }
        let descriptor = ImageSortDescriptor(key: .labels, ascending: true)

        let sorted = try await cancellableMergeSort(snapshots, by: descriptor.compare)

        XCTAssertEqual(sorted.count, snapshots.count)
        XCTAssertEqual(sorted.map(\.labelCount), sorted.map(\.labelCount).sorted())
        XCTAssertEqual(Set(sorted.map(\.id)), Set(snapshots.map(\.id)))
    }

    func testMergeFromYOLODataYAMLCopiesImagesAndAnnotations() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let sourceImages = source.appendingPathComponent("images/train", isDirectory: true)
        let sourceLabels = source.appendingPathComponent("labels/train", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceImages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceLabels, withIntermediateDirectories: true)
        try "path: .\ntrain: images/train\nval: images/val\nnames: [bird]\n".write(to: source.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
        try TestSupport.writeTinyPNG(to: sourceImages.appendingPathComponent("bird.png"))
        try "0 0.5 0.5 0.5 0.5\n".write(to: sourceLabels.appendingPathComponent("bird.txt"), atomically: true, encoding: .utf8)

        let services = LocalDatasetServices()
        let targetDataset = try await services.createDataset(named: "Target", at: target, syncFormat: .yoloDetection)
        let merged = try await services.mergeDataset(from: source.appendingPathComponent("data.yaml"), into: targetDataset)

        let image = try XCTUnwrap(merged.images.first)
        XCTAssertEqual(image.relativePath, "images/train/bird.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(image.relativePath).path))
        XCTAssertEqual(merged.annotations.count, 1)
        XCTAssertEqual(merged.annotations.first?.imageID, image.id)
    }

    func testMergeFromNestedCOCOJSONCopiesSiblingImages() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let imageDirectory = source.appendingPathComponent("images/train", isDirectory: true)
        let annotationDirectory = source.appendingPathComponent("annotations/train", isDirectory: true)
        let jsonURL = annotationDirectory.appendingPathComponent("instances.json")
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationDirectory, withIntermediateDirectories: true)
        try TestSupport.writeTinyPNG(to: imageDirectory.appendingPathComponent("frame.png"))
        let json = """
        {"images":[{"id":1,"file_name":"frame.png","width":1,"height":1}],"annotations":[],"categories":[]}
        """
        try json.write(to: jsonURL, atomically: true, encoding: .utf8)

        let services = LocalDatasetServices()
        let targetDataset = try await services.createDataset(named: "Target", at: target, syncFormat: .coco)
        let merged = try await services.mergeDataset(from: jsonURL, into: targetDataset)

        let image = try XCTUnwrap(merged.images.first)
        XCTAssertEqual(image.relativePath, "images/imported/frame.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(image.relativePath).path))
    }

    func testMergePreservesSourceTagsAndAddsDatasetDateProvenanceTag() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let sourceImages = source.appendingPathComponent("images/train", isDirectory: true)
        let sourceLabels = source.appendingPathComponent("labels/train", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceImages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceLabels, withIntermediateDirectories: true)
        try "path: .\ntrain: images/train\nval: images/val\nnames: [bird]\n".write(to: source.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
        try TestSupport.writeTinyPNG(to: sourceImages.appendingPathComponent("bird.png"))
        try "0 0.5 0.5 0.5 0.5\n".write(to: sourceLabels.appendingPathComponent("bird.txt"), atomically: true, encoding: .utf8)

        let services = LocalDatasetServices()
        let createdSource = try await services.createDataset(named: "Source Dataset", at: source, syncFormat: .yoloDetection)
        let sourceTag = DatasetTag(name: "reviewed", colorHex: "#00AA00")
        let sourceImage = DatasetImage(
            fileName: "bird.png",
            relativePath: "images/train/bird.png",
            size: .init(width: 1, height: 1),
            split: .train,
            tagIDs: [sourceTag.id]
        )
        let taggedSource = AnnotationDataset(
            id: createdSource.id,
            name: "Source Dataset",
            images: [sourceImage],
            categories: createdSource.categories,
            tags: [sourceTag],
            metadata: createdSource.metadata
        )
        try await ProjectPersistence(directoryURL: source.appendingPathComponent(".lightlabel")).save(taggedSource)

        let targetDataset = try await services.createDataset(named: "Target", at: target, syncFormat: .yoloDetection)
        let merged = try await services.mergeDataset(from: source.appendingPathComponent("data.yaml"), into: targetDataset)

        let image = try XCTUnwrap(merged.images.first)
        let imageTagNames = image.tagIDs.compactMap { id in merged.tags.first(where: { $0.id == id })?.name }
        XCTAssertTrue(imageTagNames.contains("reviewed"))
        XCTAssertTrue(imageTagNames.contains { $0.hasPrefix("Source Dataset-") && $0.count == "Source Dataset-YYYY-MM-DD".count })
        XCTAssertEqual(merged.tags.count, 2)
    }
}
