import XCTest

@testable import LightLabel

final class NonMaximumSuppressionTests: XCTestCase {
    func testSuppressesLowerConfidenceOverlappingDetectionOfSameClass() {
        let high = detection(category: 0, confidence: 0.9, box: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let low = detection(category: 0, confidence: 0.6, box: .init(x: 0.12, y: 0.12, width: 0.5, height: 0.5))
        let separate = detection(category: 0, confidence: 0.7, box: .init(x: 0.7, y: 0.7, width: 0.2, height: 0.2))

        let result = NonMaximumSuppression(intersectionOverUnionThreshold: 0.5).apply(to: [low, separate, high])

        XCTAssertEqual(result.map(\.id), [high.id, separate.id])
    }

    func testClassAwareNMSRetainsOverlappingDifferentClasses() {
        let first = detection(category: 0, confidence: 0.9, box: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let second = detection(category: 1, confidence: 0.8, box: first.boundingBox)

        let classAware = NonMaximumSuppression(classAgnostic: false).apply(to: [first, second])
        let classAgnostic = NonMaximumSuppression(classAgnostic: true).apply(to: [first, second])

        XCTAssertEqual(classAware.count, 2)
        XCTAssertEqual(classAgnostic.map(\.id), [first.id])
    }

    func testIntersectionOverUnion() {
        let first = BoundingBox(x: 0, y: 0, width: 0.5, height: 0.5)
        let second = BoundingBox(x: 0.25, y: 0, width: 0.5, height: 0.5)

        XCTAssertEqual(first.intersectionOverUnion(with: second), 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(first.intersectionOverUnion(with: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.1)), 0)
    }

    private func detection(category: Int, confidence: Double, box: BoundingBox) -> InferenceDetection {
        .init(categoryIndex: category, confidence: confidence, boundingBox: box)
    }
}
