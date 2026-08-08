import Foundation
import XCTest

@testable import LightLabel

final class CategoryMergeTests: XCTestCase {
    @MainActor
    func testRenamingCategoryToExistingNameMergesAnnotations() throws {
        let model = AppModel()
        let catA = DatasetCategory(name: "dog")
        let catB = DatasetCategory(name: "cat")
        let image = DatasetImage(id: UUID(), fileName: "img.png", size: PixelSize(width: 100, height: 100))
        model.dataset = AnnotationDataset(
            name: "Test",
            images: [image],
            categories: [catA, catB],
            annotations: [
                DatasetAnnotation(id: UUID(), imageID: image.id, categoryID: catA.id, geometry: .boundingBox(.init(x: 0, y: 0, width: 1, height: 1))),
                DatasetAnnotation(id: UUID(), imageID: image.id, categoryID: catB.id, geometry: .boundingBox(.init(x: 0, y: 0, width: 1, height: 1)))
            ]
        )

        model.updateCategory(id: catB.id, name: "dog")

        let dataset = try XCTUnwrap(model.dataset)
        XCTAssertEqual(dataset.categories.count, 1)
        XCTAssertEqual(dataset.categories.first?.name, "dog")
        XCTAssertTrue(dataset.annotations.allSatisfy { $0.categoryID == catA.id })
        XCTAssertEqual(dataset.annotations.count, 2)
        XCTAssertEqual(model.selectedCategoryID, catA.id)
    }

    @MainActor
    func testRenamingCategoryToExistingNameIsCaseInsensitive() throws {
        let model = AppModel()
        let catA = DatasetCategory(name: "Dog")
        let catB = DatasetCategory(name: "cat")
        let image = DatasetImage(id: UUID(), fileName: "img.png", size: PixelSize(width: 100, height: 100))
        model.dataset = AnnotationDataset(
            name: "Test",
            images: [image],
            categories: [catA, catB],
            annotations: [
                DatasetAnnotation(id: UUID(), imageID: image.id, categoryID: catB.id, geometry: .boundingBox(.init(x: 0, y: 0, width: 1, height: 1)))
            ]
        )

        model.updateCategory(id: catB.id, name: "DOG")

        let dataset = try XCTUnwrap(model.dataset)
        XCTAssertEqual(dataset.categories.count, 1)
        XCTAssertEqual(dataset.categories.first?.name, "Dog")
        XCTAssertTrue(dataset.annotations.allSatisfy { $0.categoryID == catA.id })
    }

    @MainActor
    func testRenamingCategoryToUniqueNameKeepsCategory() throws {
        let model = AppModel()
        let catA = DatasetCategory(name: "dog")
        let catB = DatasetCategory(name: "cat")
        let image = DatasetImage(id: UUID(), fileName: "img.png", size: PixelSize(width: 100, height: 100))
        model.dataset = AnnotationDataset(
            name: "Test",
            images: [image],
            categories: [catA, catB],
            annotations: [
                DatasetAnnotation(id: UUID(), imageID: image.id, categoryID: catB.id, geometry: .boundingBox(.init(x: 0, y: 0, width: 1, height: 1)))
            ]
        )

        model.updateCategory(id: catB.id, name: "bird")

        let dataset = try XCTUnwrap(model.dataset)
        XCTAssertEqual(dataset.categories.count, 2)
        XCTAssertEqual(dataset.categories.first(where: { $0.id == catB.id })?.name, "bird")
        XCTAssertEqual(dataset.annotations.first?.categoryID, catB.id)
    }
}
