#if os(macOS)
import XCTest
import SwiftUI
@testable import Rubien
@testable import RubienCore

@MainActor
final class ReferenceCellInsertionLayoutTests: XCTestCase {
    struct Probe: View {
        let rows: [Reference]
        @Binding var selection: Set<Reference.ID>

        @State private var sortOrder = [KeyPathComparator(\Reference.dateAdded, order: .reverse)]
        @State private var columnCustomization = TableColumnCustomization<Reference>()

        var body: some View {
            Table(
                of: Reference.self,
                selection: $selection,
                sortOrder: $sortOrder,
                columnCustomization: $columnCustomization
            ) {
                TableColumn("Title", value: \.title) { row in
                    EditableStringCell(
                        value: row.title,
                        isEditing: false,
                        onBeginEdit: {},
                        onCommit: { _ in },
                        onCancel: {},
                        wrap: true,
                        displayLineLimit: 2,
                        verticalPadding: 6
                    )
                    .equatable()
                    .background(ReferenceRowSelectionBackground(
                        isSelected: selection.contains(row.id),
                        accent: .controlAccentColor
                    ))
                }
                .width(360)
                .customizationID(ColumnIdentifier.title.rawValue)
                TableColumn("Other") { _ in
                    Text("—")
                }
                .width(100)
                .customizationID("other")
            } rows: {
                ForEach(rows) { row in
                    TableRow(row)
                }
            }
        }
    }

    func testInsertedReferenceFitsResolvedTitleWithoutByline() async throws {
        var initial = (1...30).map { i in
            var r = Reference(title: "Existing title \(i)")
            r.id = Int64(i)
            return r
        }
        var selection: Set<Reference.ID> = []
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let host = NSHostingController(rootView: Probe(rows: initial, selection: binding))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.view.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        window.contentViewController = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        func find(_ view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            return view.subviews.lazy.compactMap { find($0) }.first
        }

        try await Task.sleep(for: .milliseconds(300))
        let table = try XCTUnwrap(find(host.view))
        let resolvedTitles = [
            "A long blog title about software development tools and the future of artificial intelligence in everyday research",
            "将Softmax Attention线性化为Gated DeltaNet - 科学空间|Scientific Spaces",
        ]
        for (offset, title) in resolvedTitles.enumerated() {
            let i = 31 + offset
            var new = Reference(title: "Untitled")
            new.id = Int64(i)
            initial.insert(new, at: 0)
            selection = [new.id]
            host.rootView = Probe(rows: initial, selection: binding)
            try await Task.sleep(for: .milliseconds(5))
            initial[0].title = title
            host.rootView = Probe(rows: initial, selection: binding)
            try await Task.sleep(for: .milliseconds(100))
            let expectedCell = EditableStringCell(
                value: title,
                isEditing: false,
                onBeginEdit: {},
                onCommit: { _ in },
                onCancel: {},
                wrap: true,
                displayLineLimit: 2,
                verticalPadding: 6
            )
            let expected = NSHostingController(rootView: expectedCell)
                .sizeThatFits(in: CGSize(width: 360, height: 1_000)).height
            XCTAssertGreaterThanOrEqual(
                table.rect(ofRow: 0).height,
                expected,
                "An inserted reference must grow when its placeholder resolves to a wrapped title"
            )
        }
    }
}
#endif
