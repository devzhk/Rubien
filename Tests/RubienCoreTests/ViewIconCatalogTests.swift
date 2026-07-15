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

    func testCatalogFillsFourByNineGrid() {
        XCTAssertEqual(ViewIconCatalog.all.count, 36)
        XCTAssertEqual(ViewIconCatalog.options.count, ViewIconCatalog.all.count)
    }

    func testCatalogContainsDefaultAndNewNativeSymbols() {
        XCTAssertTrue(ViewIconCatalog.all.contains(ViewIconCatalog.defaultIcon))
        XCTAssertTrue(ViewIconCatalog.all.contains("cube"))
        XCTAssertTrue(ViewIconCatalog.all.contains("music.note"))
        XCTAssertTrue(ViewIconCatalog.all.contains("gamecontroller"))
        XCTAssertTrue(ViewIconCatalog.all.contains("movieclapper"))

        let newSymbols = ["paperplane", "sailboat", "alarm", "leaf", "carrot", "fish"]
        XCTAssertTrue(newSymbols.allSatisfy(ViewIconCatalog.all.contains))

        let expandedSymbols = [
            "heart", "bolt.square", "globe.americas", "tornado", "lizard", "tree",
            "figure.skiing.downhill", "hands.and.sparkles", "apple.terminal.on.rectangle",
        ]
        XCTAssertTrue(expandedSymbols.allSatisfy(ViewIconCatalog.all.contains))
    }

    func testDefaultIconLeadsCatalog() {
        XCTAssertEqual(ViewIconCatalog.all.first, ViewIconCatalog.defaultIcon)
    }

    func testReplacedSymbolsWereRemoved() {
        XCTAssertFalse(ViewIconCatalog.all.contains("square.stack"))
        XCTAssertFalse(ViewIconCatalog.all.contains("rectangle.stack"))
        XCTAssertFalse(ViewIconCatalog.all.contains("square.grid.2x2"))
        XCTAssertFalse(ViewIconCatalog.all.contains("pawprint"))
        XCTAssertFalse(ViewIconCatalog.all.contains("teddybear"))
        XCTAssertFalse(ViewIconCatalog.all.contains("books.vertical"))
    }

    func testNewViewUsesCatalogDefaultIcon() {
        let view = DatabaseView(name: "Untitled")
        XCTAssertEqual(view.icon, ViewIconCatalog.defaultIcon)
        XCTAssertEqual(view.icon, "folder")
    }
}
