import XCTest
@testable import RubienCore

final class ViewIconCatalogTests: XCTestCase {

    func testCatalogIsNonEmpty() {
        XCTAssertFalse(ViewIconCatalog.all.isEmpty)
    }

    func testCatalogHasNoDuplicates() {
        XCTAssertEqual(
            ViewIconCatalog.all.count,
            Set(ViewIconCatalog.all).count,
            "Curated icon catalog must not contain duplicate symbols"
        )
    }

    func testCatalogContainsDefaultAndCube() {
        XCTAssertTrue(ViewIconCatalog.all.contains(ViewIconCatalog.defaultIcon))
        XCTAssertTrue(ViewIconCatalog.all.contains("cube"))
    }

    func testNewViewUsesCatalogDefaultIcon() {
        let view = DatabaseView(name: "Untitled")
        XCTAssertEqual(view.icon, ViewIconCatalog.defaultIcon)
        XCTAssertEqual(view.icon, "square.stack")
    }
}
