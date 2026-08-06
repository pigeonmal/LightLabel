import Foundation
import XCTest

@testable import LightLabel

final class COCOFormatTests: XCTestCase {
    func testDetectionImportConvertsPixelBoxToNormalizedCoordinates() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let url = directory.appendingPathComponent("detection.json")
        try TestSupport.writeFixture("coco-detection.json", to: url)

        let result = try COCOImporter().importDataset(at: url)

        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.dataset.images.first?.sourceID, 10)
        XCTAssertEqual(result.dataset.categories.first?.sourceID, 3)
        let annotation = try XCTUnwrap(result.dataset.annotations.first)
        XCTAssertEqual(annotation.sourceID, 42)
        XCTAssertTrue(annotation.attributes.isCrowd)
        XCTAssertEqual(annotation.attributes.confidence, 0.8)
        guard case let .boundingBox(box) = annotation.geometry else {
            return XCTFail("Expected a bounding box")
        }
        XCTAssertEqual(box, BoundingBox(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
    }

    func testPolygonImportUsesLargestSegmentAndReportsMultipartWarning() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let url = directory.appendingPathComponent("segmentation.json")
        try TestSupport.writeFixture("coco-segmentation.json", to: url)

        let result = try COCOImporter().importDataset(at: url)

        let annotation = try XCTUnwrap(result.dataset.annotations.first)
        guard case let .polygon(polygon) = annotation.geometry else {
            return XCTFail("Expected a polygon")
        }
        XCTAssertEqual(polygon.points, [
            .init(x: 0.1, y: 0.2), .init(x: 0.6, y: 0.2),
            .init(x: 0.6, y: 0.7), .init(x: 0.1, y: 0.7)
        ])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].message.contains("largest"))
    }

    func testExportUsesPixelCoordinatesAreaAndDeterministicOrdering() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let output = directory.appendingPathComponent("annotations.json")
        let image = DatasetImage(fileName: "frame.png", relativePath: "images/frame.png", size: .init(width: 200, height: 100), split: .validation)
        let category = DatasetCategory(name: "object")
        let polygon = Polygon(points: [
            .init(x: 0.1, y: 0.2), .init(x: 0.6, y: 0.2),
            .init(x: 0.6, y: 0.7), .init(x: 0.1, y: 0.7)
        ])
        let dataset = AnnotationDataset(
            name: "Export Fixture",
            images: [image],
            categories: [category],
            annotations: [.init(imageID: image.id, categoryID: category.id, geometry: .polygon(polygon), sourceID: 77)]
        )

        let result = try COCOExporter().export(dataset, to: output)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        let annotations = try XCTUnwrap(object["annotations"] as? [[String: Any]])
        let exported = try XCTUnwrap(annotations.first)

        XCTAssertEqual(result.filesWritten, 1)
        XCTAssertEqual(exported["id"] as? Int, 77)
        let bbox = try XCTUnwrap(exported["bbox"] as? [Double])
        XCTAssertEqual(bbox.count, 4)
        XCTAssertEqual(bbox[0], 20, accuracy: 0.000_001)
        XCTAssertEqual(bbox[1], 20, accuracy: 0.000_001)
        XCTAssertEqual(bbox[2], 100, accuracy: 0.000_001)
        XCTAssertEqual(bbox[3], 50, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(exported["area"] as? Double), 5_000, accuracy: 0.000_001)
        XCTAssertEqual((exported["segmentation"] as? [[Double]])?.first, [20, 20, 120, 20, 120, 70, 20, 70])

        let roundTrip = try COCOImporter().importDataset(at: output)
        XCTAssertEqual(roundTrip.dataset.annotations.first?.geometry, .polygon(polygon))
    }
}
