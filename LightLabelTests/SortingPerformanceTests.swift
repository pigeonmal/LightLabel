import Foundation
import XCTest

@testable import LightLabel

final class SortingPerformanceTests: XCTestCase {
    @MainActor
    func testFoldedSortKeyMatchesFinderNaturalOrdering() throws {
        let model = AppModel()
        model.dataset = AnnotationDataset(name: "Test", images: [
            makeImage("img10.png"),
            makeImage("img2.png"),
            makeImage("img1.png"),
            makeImage("IMG3.png"),
            makeImage("áa.png"),
            makeImage("zz.png")
        ])
        model.imageSortKey = .name
        model.imageSortAscending = true

        let names = model.browserImages.map(\.fileName)
        XCTAssertEqual(names, ["áa.png", "img1.png", "img2.png", "IMG3.png", "img10.png", "zz.png"])
    }

    @MainActor
    func testBrowserImagesSortsLargeDatasetQuickly() throws {
        let model = AppModel()
        var images: [DatasetImage] = []
        for index in (0..<60_000).reversed() {
            images.append(makeImage(String(format: "photo_%05d.jpg", index)))
        }
        model.dataset = AnnotationDataset(name: "Test", images: images)
        model.imageSortKey = .name
        model.imageSortAscending = true

        let start = Date()
        let names = model.browserImages.map(\.fileName)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(names.count, 60_000)
        XCTAssertEqual(names.first, "photo_00000.jpg")
        XCTAssertEqual(names.last, "photo_59999.jpg")
        XCTAssertLessThan(elapsed, 3.0, "Name sort of 60k images took \(elapsed)s")
    }

    @MainActor
    private func makeImage(_ name: String) -> DatasetImage {
        DatasetImage(id: UUID(), fileName: name, relativePath: name, size: PixelSize(width: 1920, height: 1080))
    }
}
