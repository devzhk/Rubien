import Foundation

/// Projects Defuddle/Readability HTML fragments into compact Markdown for
/// agent-facing reads. This is deliberately a representation converter, not
/// an HTML sanitizer: the canonical reader still renders the stored HTML.
enum HTMLToMarkdownConverter {
    static let version = 1

    static func convert(_ html: String) -> String {
        var renderer = Renderer()
        let bytes = Array(html.utf8)
        var index = 0

        while index < bytes.count {
            if renderer.isSuppressing {
                guard bytes[index] == 0x3C, // <
                      let end = tagEnd(in: bytes, from: index + 1) else {
                    index += 1
                    continue
                }
                let raw = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                if let tag = Tag(raw), renderer.consumeSuppressed(tag) {
                    index = end + 1
                    continue
                }
                index = end + 1
                continue
            }

            if bytes[index] != 0x3C { // <
                let start = index
                while index < bytes.count, bytes[index] != 0x3C { index += 1 }
                renderer.text(String(decoding: bytes[start..<index], as: UTF8.self))
                continue
            }

            if bytes[index...].starts(with: [0x3C, 0x21, 0x2D, 0x2D]), // <!--
               let end = find([0x2D, 0x2D, 0x3E], in: bytes, from: index + 4) {
                index = end + 3
                continue
            }

            guard let end = tagEnd(in: bytes, from: index + 1) else {
                renderer.text("<")
                index += 1
                continue
            }
            let raw = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
            if let tag = Tag(raw) {
                renderer.tag(tag)
            }
            index = end + 1
        }

        return renderer.finish()
    }

    private static func tagEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var quote: UInt8?
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if byte == activeQuote { quote = nil }
            } else if byte == 0x22 || byte == 0x27 { // " or '
                quote = byte
            } else if byte == 0x3E { // >
                return index
            }
            index += 1
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        var index = start
        while index <= bytes.count - needle.count {
            if bytes[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    private struct Tag {
        let name: String
        let attributes: [String: String]
        let isClosing: Bool
        let isSelfClosing: Bool

        init?(_ rawTag: String) {
            var raw = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.hasPrefix("!") && !raw.hasPrefix("?") else { return nil }

            let closing = raw.hasPrefix("/")
            if closing { raw.removeFirst() }
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let selfClosing = raw.hasSuffix("/")
            if selfClosing { raw.removeLast() }
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            let nameEnd = raw.firstIndex { $0.isWhitespace || $0 == "/" } ?? raw.endIndex
            let parsedName = raw[..<nameEnd].lowercased()
            guard !parsedName.isEmpty else { return nil }

            name = parsedName
            isClosing = closing
            isSelfClosing = selfClosing
            attributes = closing ? [:] : Self.parseAttributes(String(raw[nameEnd...]))
        }

        private static func parseAttributes(_ raw: String) -> [String: String] {
            let characters = Array(raw)
            var result: [String: String] = [:]
            var index = 0

            while index < characters.count {
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                guard index < characters.count else { break }

                let nameStart = index
                while index < characters.count,
                      !characters[index].isWhitespace,
                      characters[index] != "=" {
                    index += 1
                }
                let name = String(characters[nameStart..<index]).lowercased()
                while index < characters.count, characters[index].isWhitespace { index += 1 }

                var value = ""
                if index < characters.count, characters[index] == "=" {
                    index += 1
                    while index < characters.count, characters[index].isWhitespace { index += 1 }
                    if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                        let quote = characters[index]
                        index += 1
                        let valueStart = index
                        while index < characters.count, characters[index] != quote { index += 1 }
                        value = String(characters[valueStart..<index])
                        if index < characters.count { index += 1 }
                    } else {
                        let valueStart = index
                        while index < characters.count, !characters[index].isWhitespace { index += 1 }
                        value = String(characters[valueStart..<index])
                    }
                }
                if !name.isEmpty { result[name] = HTMLToMarkdownConverter.decodeEntities(value) }
            }
            return result
        }
    }

    private struct ListContext {
        var ordered: Bool
        var nextNumber: Int
    }

    private struct Renderer {
        private var output = ""
        private var suppressedTag: String?
        private var suppressedDepth = 0
        private var lists: [ListContext] = []
        private var listItemDepth = 0
        private var links: [String?] = []
        private var quoteDepth = 0
        private var preDepth = 0
        private var preContent = ""
        private var preLanguage = ""
        private var inlineCodeContent: String?
        private var tableDepth = 0
        private var tableCellDepth = 0
        private var tableRowNumber = 0
        private var tableCellCount = 0

        var isSuppressing: Bool { suppressedTag != nil }

        mutating func consumeSuppressed(_ tag: Tag) -> Bool {
            guard let suppressedTag, tag.name == suppressedTag else { return false }
            if tag.isClosing {
                suppressedDepth -= 1
                if suppressedDepth == 0 { self.suppressedTag = nil }
            } else if !tag.isSelfClosing {
                suppressedDepth += 1
            }
            return true
        }

        mutating func text(_ raw: String) {
            guard !raw.isEmpty else { return }
            let decoded = HTMLToMarkdownConverter.decodeEntities(raw)
            if preDepth > 0 {
                if preContent.isEmpty,
                   decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
                preContent += decoded
                return
            }

            let normalized = decoded.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            guard !normalized.isEmpty else { return }
            if inlineCodeContent != nil {
                inlineCodeContent! += normalized
                return
            }
            var value = tableCellDepth > 0
                ? normalized.replacingOccurrences(of: "|", with: #"\|"#)
                : normalized
            if output.isEmpty || output.last == "\n" {
                while value.first == " " { value.removeFirst() }
            }
            if output.last == " ", value.first == " " { value.removeFirst() }
            output += value
        }

        mutating func tag(_ tag: Tag) {
            if tag.isClosing {
                close(tag.name)
                return
            }

            if preDepth > 0 {
                if tag.name == "code", preLanguage.isEmpty {
                    preLanguage = language(in: tag.attributes["class"])
                } else if tag.name == "br" {
                    preContent += "\n"
                }
                return
            }
            if inlineCodeContent != nil, tag.name != "code" {
                if tag.name == "br" { inlineCodeContent! += " " }
                return
            }

            switch tag.name {
            case "script", "style", "noscript", "template", "svg":
                suppress(tag.name, selfClosing: tag.isSelfClosing)
            case "math":
                renderMath(tag.attributes)
                suppress(tag.name, selfClosing: tag.isSelfClosing)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                blockStart()
                let level = Int(String(tag.name.last ?? "1")) ?? 1
                output += String(repeating: "#", count: level) + " "
            case "p":
                if tableDepth == 0 && listItemDepth == 0 {
                    quoteDepth > 0 ? quoteLineStart() : blockStart()
                }
            case "article", "section", "main", "figure", "figcaption", "details", "summary":
                if tableDepth == 0 { blockStart() }
            case "div", "header", "footer", "aside", "nav":
                if tableDepth == 0 { ensureNewlines(1) }
            case "br":
                ensureNewlines(1)
                if quoteDepth > 0 { output += String(repeating: "> ", count: quoteDepth) }
            case "hr":
                blockStart(); output += "---"; blockEnd()
            case "strong", "b": output += "**"
            case "em", "i": output += "*"
            case "del", "s", "strike": output += "~~"
            case "blockquote":
                blockStart()
                quoteDepth += 1
                output += String(repeating: "> ", count: quoteDepth)
            case "ul":
                blockStart()
                lists.append(ListContext(ordered: false, nextNumber: 1))
            case "ol":
                blockStart()
                let start = Int(tag.attributes["start"] ?? "") ?? 1
                lists.append(ListContext(ordered: true, nextNumber: start))
            case "li":
                ensureNewlines(1)
                let depth = max(0, lists.count - 1)
                output += String(repeating: "  ", count: depth)
                if var list = lists.popLast() {
                    output += list.ordered ? "\(list.nextNumber). " : "- "
                    list.nextNumber += 1
                    lists.append(list)
                } else {
                    output += "- "
                }
                listItemDepth += 1
            case "a":
                let href = tag.attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                links.append(href)
                if href?.isEmpty == false { output += "[" }
            case "img":
                let source = tag.attributes["src"] ?? tag.attributes["data-src"]
                let alt = tag.attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let source, !source.isEmpty { output += "![\(alt)](\(source))" }
                else if !alt.isEmpty { output += alt }
            case "iframe":
                if let source = tag.attributes["src"], !source.isEmpty {
                    output += "[Embedded content](\(source))"
                }
            case "pre":
                blockStart()
                preDepth += 1
                preContent = ""
                preLanguage = language(in: tag.attributes["class"])
            case "code":
                inlineCodeContent = ""
            case "table":
                blockStart()
                tableDepth += 1
                tableRowNumber = 0
            case "tr":
                ensureNewlines(1)
                output += "| "
                tableCellCount = 0
            case "td", "th":
                tableCellDepth += 1
                tableCellCount += 1
            default:
                break
            }

            if tag.isSelfClosing { close(tag.name) }
        }

        mutating func close(_ name: String) {
            if preDepth > 0, name != "pre" {
                return
            }
            if inlineCodeContent != nil, name != "code" {
                return
            }

            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6", "p",
                 "article", "section", "main", "figure", "figcaption", "details", "summary":
                if tableDepth == 0 && listItemDepth == 0 { blockEnd() }
            case "div", "header", "footer", "aside", "nav":
                if tableDepth == 0 { ensureNewlines(1) }
            case "strong", "b": output += "**"
            case "em", "i": output += "*"
            case "del", "s", "strike": output += "~~"
            case "blockquote":
                quoteDepth = max(0, quoteDepth - 1)
                blockEnd()
            case "ul", "ol":
                if !lists.isEmpty { lists.removeLast() }
                blockEnd()
            case "li":
                listItemDepth = max(0, listItemDepth - 1)
                ensureNewlines(1)
            case "a":
                if let href = links.popLast() ?? nil, !href.isEmpty { output += "](\(href))" }
            case "code":
                if let content = inlineCodeContent {
                    output += codeSpan(content)
                    inlineCodeContent = nil
                }
            case "pre":
                while preContent.last == "\n" { preContent.removeLast() }
                let fence = backtickFence(for: preContent, minimumLength: 3)
                output += "\(fence)\(preLanguage)\n\(preContent)\n\(fence)"
                preDepth = max(0, preDepth - 1)
                preContent = ""
                preLanguage = ""
                blockEnd()
            case "td", "th":
                tableCellDepth = max(0, tableCellDepth - 1)
                trimTrailingHorizontalWhitespace()
                output += " | "
            case "tr":
                trimTrailingHorizontalWhitespace()
                ensureNewlines(1)
                if tableRowNumber == 0, tableCellCount > 0 {
                    output += "| " + Array(repeating: "---", count: tableCellCount).joined(separator: " | ") + " |"
                    ensureNewlines(1)
                }
                tableRowNumber += 1
            case "table":
                tableDepth = max(0, tableDepth - 1)
                blockEnd()
            default:
                break
            }
        }

        mutating func finish() -> String {
            if preDepth > 0 { close("pre") }
            if inlineCodeContent != nil { close("code") }
            var cleaned = output.replacingOccurrences(
                of: #"[ \t]+\n"#,
                with: "\n",
                options: .regularExpression
            )
            cleaned = cleaned.replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private mutating func suppress(_ name: String, selfClosing: Bool) {
            guard !selfClosing else { return }
            suppressedTag = name
            suppressedDepth = 1
        }

        private mutating func renderMath(_ attributes: [String: String]) {
            let latex = (attributes["data-latex"] ?? attributes["alttext"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return }
            let isBlock = attributes["display"]?.lowercased() == "block"
                || attributes["displaystyle"]?.lowercased() == "true"
            if isBlock {
                blockStart()
                output += "$$\n\(latex)\n$$"
                blockEnd()
            } else {
                output += "$\(latex)$"
            }
        }

        private mutating func quoteLineStart() {
            ensureNewlines(output.isEmpty ? 0 : 1)
            output += String(repeating: "> ", count: quoteDepth)
        }

        private mutating func blockStart() {
            guard !output.isEmpty else { return }
            ensureNewlines(2)
        }

        private mutating func blockEnd() {
            ensureNewlines(2)
        }

        private mutating func ensureNewlines(_ count: Int) {
            guard count > 0 else { return }
            trimTrailingHorizontalWhitespace()
            var trailing = 0
            for character in output.reversed() {
                guard character == "\n" else { break }
                trailing += 1
            }
            if trailing < count { output += String(repeating: "\n", count: count - trailing) }
        }

        private mutating func trimTrailingHorizontalWhitespace() {
            while output.last == " " || output.last == "\t" { output.removeLast() }
        }

        private func codeSpan(_ content: String) -> String {
            let fence = backtickFence(for: content, minimumLength: 1)
            let needsPadding = content.first == "`" || content.last == "`"
                || content.first == " " || content.last == " "
            return needsPadding
                ? "\(fence) \(content) \(fence)"
                : "\(fence)\(content)\(fence)"
        }

        private func backtickFence(for content: String, minimumLength: Int) -> String {
            var longestRun = 0
            var currentRun = 0
            for character in content {
                if character == "`" {
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 0
                }
            }
            return String(repeating: "`", count: max(minimumLength, longestRun + 1))
        }

        private func language(in className: String?) -> String {
            guard let className else { return "" }
            for token in className.split(whereSeparator: \.isWhitespace) {
                if token.hasPrefix("language-") { return String(token.dropFirst("language-".count)) }
                if token.hasPrefix("lang-") { return String(token.dropFirst("lang-".count)) }
            }
            return ""
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
            "copy": "©", "reg": "®", "trade": "™", "laquo": "«", "raquo": "»"
        ]
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].prefix(16).firstIndex(of: ";") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let entityStart = text.index(after: index)
            let entity = String(text[entityStart..<semicolon])
            let decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init).map(String.init)
            } else {
                decoded = named[entity.lowercased()]
            }
            if let decoded {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append("&")
                index = entityStart
            }
        }
        return result
    }
}
