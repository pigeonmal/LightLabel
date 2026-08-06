import CoreGraphics
import XCTest

@testable import LightLabel

final class GeometryConversionTests: XCTestCase {
    func testNormalizedPixelRoundTrip() {
        let transform = CanvasTransform(
            imageSize: PixelSize(width: 640, height: 480),
            canvasSize: CGSize(width: 1000, height: 800)
        )
        let normalized = NormalizedPoint(x: 0.25, y: 0.75)

        let pixel = transform.pixelPoint(from: normalized)

        XCTAssertEqual(pixel.x, 160, accuracy: 0.000_001)
        XCTAssertEqual(pixel.y, 360, accuracy: 0.000_001)
        XCTAssertEqual(transform.normalizedPoint(fromPixel: pixel).x, normalized.x, accuracy: 0.000_001)
        XCTAssertEqual(transform.normalizedPoint(fromPixel: pixel).y, normalized.y, accuracy: 0.000_001)
    }

    func testAspectFitCanvasPointAndBoxRoundTrip() {
        let transform = CanvasTransform(
            imageSize: PixelSize(width: 400, height: 200),
            canvasSize: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(transform.scale, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(transform.imageFrame, CGRect(x: 0, y: 75, width: 300, height: 150))

        let point = NormalizedPoint(x: 0.5, y: 0.25)
        let canvasPoint = transform.canvasPoint(from: point)
        XCTAssertEqual(canvasPoint.x, 150, accuracy: 0.000_001)
        XCTAssertEqual(canvasPoint.y, 112.5, accuracy: 0.000_001)
        XCTAssertEqual(transform.normalizedPoint(from: canvasPoint).x, point.x, accuracy: 0.000_001)
        XCTAssertEqual(transform.normalizedPoint(from: canvasPoint).y, point.y, accuracy: 0.000_001)

        let box = BoundingBox(x: 0.1, y: 0.2, width: 0.4, height: 0.5)
        let roundTrip = transform.normalizedBox(from: transform.canvasRect(from: box))
        XCTAssertEqual(roundTrip.x, box.x, accuracy: 0.000_001)
        XCTAssertEqual(roundTrip.y, box.y, accuracy: 0.000_001)
        XCTAssertEqual(roundTrip.width, box.width, accuracy: 0.000_001)
        XCTAssertEqual(roundTrip.height, box.height, accuracy: 0.000_001)
    }

    func testClampedCanvasConversionRestrictsCoordinatesToImage() {
        let transform = CanvasTransform(
            imageSize: PixelSize(width: 100, height: 100),
            canvasSize: CGSize(width: 200, height: 100)
        )

        let point = transform.normalizedPoint(from: CGPoint(x: -20, y: 150), clamp: true)
        XCTAssertEqual(point, NormalizedPoint(x: 0, y: 1))

        let box = transform.normalizedBox(from: CGRect(x: 25, y: -10, width: 200, height: 80), clamp: true)
        XCTAssertEqual(box.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(box.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(box.width, 1, accuracy: 0.000_001)
        XCTAssertEqual(box.height, 0.7, accuracy: 0.000_001)
    }

    func testInvalidSizesProduceZeroTransform() {
        let transform = CanvasTransform(
            imageSize: PixelSize(width: 0, height: 10),
            canvasSize: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(transform.scale, 0)
        XCTAssertEqual(transform.imageFrame, .zero)
        XCTAssertEqual(transform.normalizedPoint(from: CGPoint(x: 50, y: 50)), NormalizedPoint(x: 0, y: 0))
    }
}
