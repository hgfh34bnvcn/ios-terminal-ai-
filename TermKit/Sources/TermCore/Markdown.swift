import Foundation

public enum Markdown {
    public struct ListItem: Equatable, Sendable {
        public var marker: String
        public var text: String
        public var indent: Int
    }

    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(language: String?, text: String)
        case list([ListItem])
        case quote(String)
        case rule
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " }.count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for (prefix, marker) in [("- [ ] ", "☐"), ("- [x] ", "☑"), ("- [X] ", "☑"), ("- ", "•"), ("* ", "•"), ("+ ", "•")]
        where trimmed.hasPrefix(prefix) {
            return ListItem(marker: marker, text: String(trimmed.dropFirst(prefix.count)), indent: indent)
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ListItem(marker: digits + ".", text: String(rest.dropFirst(2)), indent: indent)
    }

    /// Splits Markdown into blocks for rendering. A code fence still open at the end (mid-stream) is
    /// treated as code; tables are kept as preformatted text.
    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String]?
        var language: String?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !list.isEmpty { blocks.append(.list(list)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.code(language: nil, text: table.joined(separator: "\n"))) }
            paragraph = []
            list = []
            quote = []
            table = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: language, text: open.joined(separator: "\n")))
                    code = nil
                } else {
                    code = open + [line]
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                let name = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                language = name.isEmpty ? nil : name
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                flush()
                blocks.append(.heading(level: hashes, text: trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first), trimmed.allSatisfy({ $0 == first }) {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(trimmed)
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                if list.isEmpty { flush() }
                list.append(item)
                continue
            }
            if !list.isEmpty, line.hasPrefix("  ") {
                // Indented text continues the item above it.
                list[list.count - 1].text += "\n" + trimmed
                continue
            }
            if !list.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(language: language, text: open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    public static func export(_ session: Session) -> String {
        var lines = ["# \(session.title)", ""]
        for item in session.transcript {
            switch item.kind {
            case .user:
                lines.append("**> \(item.text)**")
            case .assistant:
                lines.append(item.text)
            case .tool:
                var block = "```\n\(item.tool ?? "Tool"): \(item.title ?? "")"
                if let diff = item.diff, !diff.isEmpty {
                    block += "\n" + diff
                } else if !item.text.isEmpty {
                    block += "\n" + item.text
                }
                lines.append(block + "\n```")
            case .thinking, .info, .error:
                continue
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
