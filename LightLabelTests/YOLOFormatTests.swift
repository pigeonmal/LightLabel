import Foundation
import XCTest

@testable import LightLabel

final class YOLOFormatTests: XCTestCase {
    func testDataYAMLParsesArrayAndIndexedNames() throws {
        let array = try YOLODataConfiguration.parse(TestSupport.fixture("yolo-array.yaml"))
        XCTAssertEqual(array.names, ["bird", "traffic light"])
        XCTAssertEqual(array.paths[.train], "images/train")
        XCTAssertEqual(array.paths[.validation], "images/val")

        let indexed = try YOLODataConfiguration.parse(TestSupport.fixture("yolo-indexed.yaml"))
        XCTAssertEqual(indexed.names, ["person", "hard hat"])
        XCTAssertEqual(indexed.paths[.test], "images/test")
    }

    func testDetectionImportReadsImageAndNormalizedRow() throws {
        let root = try makeYOLOFixture(labelFixture: "yolo-detection.txt")
        defer { TestSupport.removeTemporaryDirectory(root) }

        let result = try YOLOImporter().importDataset(at: root, task: .detection)

        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.dataset.images.count, 1)
        XCTAssertEqual(result.dataset.images[0].size, PixelSize(width: 1, height: 1))
        XCTAssertEqual(result.dataset.categories.map(\.name), ["bird", "traffic light"])
        let annotation = try XCTUnwrap(result.dataset.annotations.first)
        guard case let .boundingBox(box) = annotation.geometry else {
            return XCTFail("Expected a detection bounding box")
        }
        XCTAssertEqual(box, BoundingBox(x: 0.25, y: 0.3, width: 0.5, height: 0.4))
    }

    func testAutomaticImportDetectsSegmentationRow() throws {
        let root = try makeYOLOFixture(labelFixture: "yolo-segmentation.txt")
        defer { TestSupport.removeTemporaryDirectory(root) }

        let result = try YOLOImporter().importDataset(at: root, task: .automatic)

        let annotation = try XCTUnwrap(result.dataset.annotations.first)
        guard case let .polygon(polygon) = annotation.geometry else {
            return XCTFail("Expected a segmentation polygon")
        }
        XCTAssertEqual(polygon.points.count, 4)
        XCTAssertEqual(polygon.area, 0.24, accuracy: 0.000_001)
    }

    func testMalformedRowsProduceLineNumberedWarnings() throws {
        let root = try makeYOLOFixture(labelFixture: "yolo-malformed.txt")
        defer { TestSupport.removeTemporaryDirectory(root) }

        let result = try YOLOImporter().importDataset(at: root, task: .automatic)

        XCTAssertTrue(result.dataset.annotations.isEmpty)
        XCTAssertEqual(result.warnings.map(\.line), [1, 2, 3])
        XCTAssertTrue(result.warnings.allSatisfy { $0.file?.hasSuffix("tiny.txt") == true })
    }

    func testDetectionExportAndImportRoundTrip() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let dataset = makeDataset(geometry: .boundingBox(.init(x: 0.2, y: 0.3, width: 0.4, height: 0.2)))

        let export = try YOLOExporter().export(dataset, to: root, task: .detection)
        XCTAssertEqual(export.filesWritten, 2)
        XCTAssertTrue(export.warnings.isEmpty)
        let row = try String(contentsOf: root.appendingPathComponent("labels/train/tiny.txt"), encoding: .utf8)
        XCTAssertEqual(row, "0 0.4 0.4 0.4 0.2\n")

        let imageDirectory = root.appendingPathComponent("images/train", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try TestSupport.writeTinyPNG(to: imageDirectory.appendingPathComponent("tiny.png"))
        let imported = try YOLOImporter().importDataset(at: root, task: .detection)
        XCTAssertEqual(imported.dataset.annotations.count, 1)
        guard case let .boundingBox(importedBox) = try XCTUnwrap(imported.dataset.annotations.first?.geometry),
              case let .boundingBox(expectedBox) = try XCTUnwrap(dataset.annotations.first?.geometry) else {
            return XCTFail("Expected bounding boxes")
        }
        XCTAssertEqual(importedBox.x, expectedBox.x, accuracy: 0.000_001)
        XCTAssertEqual(importedBox.y, expectedBox.y, accuracy: 0.000_001)
        XCTAssertEqual(importedBox.width, expectedBox.width, accuracy: 0.000_001)
        XCTAssertEqual(importedBox.height, expectedBox.height, accuracy: 0.000_001)
    }

    func testSegmentationExportWritesPolygonAndWarnsForBox() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        var dataset = makeDataset(geometry: .polygon(.init(points: [
            .init(x: 0.1, y: 0.2), .init(x: 0.7, y: 0.2), .init(x: 0.7, y: 0.6)
        ])))
        dataset.annotations.append(.init(
            imageID: dataset.images[0].id,
            categoryID: dataset.categories[0].id,
            geometry: .boundingBox(.init(x: 0, y: 0, width: 0.1, height: 0.1))
        ))

        let result = try YOLOExporter().export(dataset, to: root, task: .segmentation)
        let row = try String(contentsOf: root.appendingPathComponent("labels/train/tiny.txt"), encoding: .utf8)

        XCTAssertEqual(row, "0 0.1 0.2 0.7 0.2 0.7 0.6\n")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].message.contains("bounding box"))
    }

    private func makeYOLOFixture(labelFixture: String) throws -> URL {
        let root = try TestSupport.makeTemporaryDirectory()
        let imageDirectory = root.appendingPathComponent("images/train", isDirectory: true)
        let labelDirectory = root.appendingPathComponent("labels/train", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: labelDirectory, withIntermediateDirectories: true)
        try TestSupport.writeFixture("yolo-array.yaml", to: root.appendingPathComponent("data.yaml"))
        try TestSupport.writeTinyPNG(to: imageDirectory.appendingPathComponent("tiny.png"))
        try TestSupport.writeFixture(labelFixture, to: labelDirectory.appendingPathComponent("tiny.txt"))
        return root
    }

    private func makeDataset(geometry: AnnotationGeometry) -> AnnotationDataset {
        let image = DatasetImage(fileName: "tiny.png", size: .init(width: 100, height: 50), split: .train)
        let category = DatasetCategory(name: "bird")
        return AnnotationDataset(
            name: "Fixture",
            images: [image],
            categories: [category],
            annotations: [.init(imageID: image.id, categoryID: category.id, geometry: geometry)]
        )
    }
}
