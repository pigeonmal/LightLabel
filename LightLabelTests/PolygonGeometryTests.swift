import XCTest

@testable import LightLabel

final class PolygonGeometryTests: XCTestCase {
    func testAreaAndBounds() throws {
        let polygon = Polygon(points: [
            .init(x: 0.1, y: 0.2),
            .init(x: 0.7, y: 0.2),
            .init(x: 0.7, y: 0.6),
            .init(x: 0.1, y: 0.6)
        ])

        XCTAssertEqual(polygon.area, 0.24, accuracy: 0.000_001)
        let bounds = try XCTUnwrap(polygon.bounds)
        XCTAssertEqual(bounds.x, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(bounds.y, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(bounds.width, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(bounds.height, 0.4, accuracy: 0.000_001)
    }

    func testValidationRejectsTooFewPointsAndZeroArea() {
        let polygon = Polygon(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.5)])

        XCTAssertTrue(polygon.validationIssues.contains(.tooFewPoints))
        XCTAssertTrue(polygon.validationIssues.contains(.zeroArea))
        XCTAssertFalse(polygon.isValid)
    }

    func testValidationRejectsOutOfBoundsAndSelfIntersection() {
        let outOfBounds = Polygon(points: [
            .init(x: -0.1, y: 0), .init(x: 0.5, y: 0), .init(x: 0.5, y: 0.5)
        ])
        let bowTie = Polygon(points: [
            .init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.9),
            .init(x: 0.1, y: 0.9), .init(x: 0.9, y: 0.1)
        ])

        XCTAssertTrue(outOfBounds.validationIssues.contains(.outOfBounds))
        XCTAssertTrue(bowTie.validationIssues.contains(.selfIntersecting))
        XCTAssertTrue(bowTie.validationIssues.contains(.zeroArea))
    }

    func testClockwiseAndCounterclockwisePolygonsHaveSameArea() {
        let points = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 0, y: 1)
        ]

        XCTAssertEqual(Polygon(points: points).area, Polygon(points: Array(points.reversed())).area, accuracy: 0.000_001)
    }
}
