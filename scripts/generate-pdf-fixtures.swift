#!/usr/bin/env swift
//
// Generate the cross-backend parity fixture PDFs used by
// Tests/RubienPDFKitTests/BackendParityTests.swift.
//
// Run once on macOS (requires full Xcode for PDFKit):
//     swift scripts/generate-pdf-fixtures.swift
//
// Output: Tests/RubienCoreTests/Fixtures/PDFs/{
//   linear-3pages-text.pdf,
//   outline-2level-5sections.pdf,
//   scan-only-1page.pdf,
//   encrypted-password.pdf
// }
//
// The generated PDFs are committed to the repo so contributors don't need
// to regenerate them. Re-run this script only when the fixture contract
// changes; if you change a fixture's text/layout the parity tests need to
// be updated in lockstep.

import Foundation
import PDFKit
import AppKit
import CoreText

let outputDir = URL(fileURLWithPath: "Tests/RubienCoreTests/Fixtures/PDFs", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Helpers

let pageWidth: CGFloat = 612   // 8.5" at 72dpi
let pageHeight: CGFloat = 792  // 11"

/// Build a `PDFPage` containing the supplied lines of text. Each line is
/// drawn at a fixed y offset using Helvetica 14pt. Selectable text is
/// guaranteed because `NSAttributedString` drawing produces a real text
/// layer (vs. drawing rasterized glyphs which would not be extractable).
func makeTextPage(title: String, body: [String]) -> PDFPage {
    let pdfData = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        fatalError("failed to create CGContext")
    }
    ctx.beginPDFPage(nil)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    let titleFont = NSFont(name: "Helvetica-Bold", size: 24)!
    let bodyFont = NSFont(name: "Helvetica", size: 14)!

    let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.black]
    let bodyAttr: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.black]

    (title as NSString).draw(at: CGPoint(x: 72, y: pageHeight - 100), withAttributes: titleAttr)
    var y: CGFloat = pageHeight - 150
    for line in body {
        (line as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: bodyAttr)
        y -= 24
    }

    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
    ctx.closePDF()

    guard let doc = PDFDocument(data: pdfData as Data), let page = doc.page(at: 0) else {
        fatalError("failed to roundtrip single page through PDFDocument")
    }
    return page
}

/// Build a PDF with the given pages and (optional) outline tree. Outline
/// tree is `[(label, pageIndex, [children])]`.
func buildPDF(pages: [PDFPage], outline: [(String, Int, [(String, Int, [(String, Int)])])] = []) -> PDFDocument {
    let doc = PDFDocument()
    for (i, page) in pages.enumerated() {
        doc.insert(page, at: i)
    }

    if !outline.isEmpty {
        let root = PDFOutline()
        for (label, pageIndex, kids) in outline {
            let node = PDFOutline()
            node.label = label
            if let page = doc.page(at: pageIndex) {
                node.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pageHeight))
            }
            for (childLabel, childPageIndex, grandKids) in kids {
                let child = PDFOutline()
                child.label = childLabel
                if let page = doc.page(at: childPageIndex) {
                    child.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pageHeight))
                }
                for (gkLabel, gkPageIndex) in grandKids {
                    let gk = PDFOutline()
                    gk.label = gkLabel
                    if let page = doc.page(at: gkPageIndex) {
                        gk.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pageHeight))
                    }
                    child.insertChild(gk, at: child.numberOfChildren)
                }
                node.insertChild(child, at: node.numberOfChildren)
            }
            root.insertChild(node, at: root.numberOfChildren)
        }
        doc.outlineRoot = root
    }

    return doc
}

func write(_ doc: PDFDocument, to filename: String, password: String? = nil) {
    let url = outputDir.appendingPathComponent(filename)
    if let pw = password {
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: pw,
            .ownerPasswordOption: pw,
        ]
        let ok = doc.write(to: url, withOptions: options)
        if !ok { fatalError("failed to write \(filename)") }
    } else {
        if !doc.write(to: url) { fatalError("failed to write \(filename)") }
    }
    print("wrote", url.lastPathComponent, "(\(((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? -1) bytes)")
}

// MARK: - Fixture 1: linear-3pages-text.pdf

let linearPages = [
    makeTextPage(title: "Linear 3 Pages", body: ["Page 1 body text", "Used by BackendParityTests"]),
    makeTextPage(title: "Page Two", body: ["Page 2 body text", "Different content"]),
    makeTextPage(title: "Page Three", body: ["Page 3 body text", "Last page"]),
]
write(buildPDF(pages: linearPages), to: "linear-3pages-text.pdf")

// MARK: - Fixture 2: outline-2level-5sections.pdf

let outlinePages = (0..<8).map { i in
    makeTextPage(title: "Section page \(i + 1)", body: ["Content on page \(i + 1)"])
}
// Outline tree:
//   Chapter 1  -> page 0
//     1.1      -> page 1
//     1.2      -> page 2
//   Chapter 2  -> page 3
//   Chapter 3  -> page 4
//     3.1      -> page 5
//   Chapter 4  -> page 6
//   Chapter 5  -> page 7
let outlineTree: [(String, Int, [(String, Int, [(String, Int)])])] = [
    ("Chapter 1", 0, [
        ("1.1", 1, []),
        ("1.2", 2, []),
    ]),
    ("Chapter 2", 3, []),
    ("Chapter 3", 4, [
        ("3.1", 5, []),
    ]),
    ("Chapter 4", 6, []),
    ("Chapter 5", 7, []),
]
write(buildPDF(pages: outlinePages, outline: outlineTree), to: "outline-2level-5sections.pdf")

// MARK: - Fixture 3: scan-only-1page.pdf

// Render a 400x500 image of a single solid block, embed it into a PDF page
// without any text. The resulting page has no selectable text layer —
// `hasTextLayer` must return false.
let scanData = NSMutableData()
var scanMediaBox = CGRect(x: 0, y: 0, width: 400, height: 500)
guard let scanConsumer = CGDataConsumer(data: scanData as CFMutableData),
      let scanCtx = CGContext(consumer: scanConsumer, mediaBox: &scanMediaBox, nil) else {
    fatalError("scan-only fixture: failed to create CGContext")
}
scanCtx.beginPDFPage(nil)

// Draw a 200x200 mid-gray rectangle. No text. CGImage embed isn't strictly
// necessary — a vector fill produces an image-free page that PDFKit and
// Poppler both treat as "no text layer".
scanCtx.setFillColor(CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1))
scanCtx.fill(CGRect(x: 100, y: 150, width: 200, height: 200))

scanCtx.endPDFPage()
scanCtx.closePDF()

let scanURL = outputDir.appendingPathComponent("scan-only-1page.pdf")
try scanData.write(to: scanURL)
print("wrote", scanURL.lastPathComponent, "(\(((try? FileManager.default.attributesOfItem(atPath: scanURL.path)[.size]) as? Int) ?? -1) bytes)")

// MARK: - Fixture 4: encrypted-password.pdf

let encryptedPages = [makeTextPage(title: "Encrypted", body: ["This page is password-protected"])]
write(buildPDF(pages: encryptedPages), to: "encrypted-password.pdf", password: "rubien-test")
