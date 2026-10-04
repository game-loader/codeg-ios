import Foundation

/// A block of Markdown, generic over the inline payload so the parser stays
/// Foundation-only (and unit-testable off-device): the app instantiates it with
/// a pre-parsed `AttributedString`, tests with the raw `String`.
enum MarkdownNode<Inline> {
    case paragraph(Inline)
    case heading(level: Int, Inline)
    case list([MarkdownListItem<Inline>])
    /// A block quote's content is itself block Markdown (paragraphs, lists,
    /// code), parsed recursively.
    case quote([MarkdownNode<Inline>])
    case code(language: String?, code: String)
    case math(latex: String, source: String)
    case rule
    case table(MarkdownTable<Inline>)
}

/// One list item. Nesting is flattened into `level` (0 = outermost), so a list
/// renders as a single block whose rows indent by depth — enough for the lists
/// agents write, without a tree of nested views.
struct MarkdownListItem<Inline> {
    typealias Marker = MarkdownListMarker

    var level: Int
    var marker: Marker
    var content: Inline
}

/// Top-level rather than nested in the generic types: a nested type is a
/// distinct type per specialization, and the parser builds these before it
/// knows the inline type.
enum MarkdownListMarker: Equatable {
    case bullet
    /// The number to display, already renumbered the way CommonMark does
    /// (`1. 1. 1.` shows 1, 2, 3; a list starting at 4 counts from 4).
    case ordered(Int)
    case task(checked: Bool)
}

enum MarkdownTableAlignment: Equatable { case leading, center, trailing }

struct MarkdownTable<Inline> {
    typealias Alignment = MarkdownTableAlignment

    var header: [Inline]
    var alignments: [Alignment]
    /// Every row is padded or truncated to the header's column count.
    var rows: [[Inline]]
}

extension MarkdownNode: Equatable where Inline: Equatable {}
extension MarkdownListItem: Equatable where Inline: Equatable {}
extension MarkdownTable: Equatable where Inline: Equatable {}

/// Splits Markdown into blocks: fenced code, ATX and setext headings, rules,
/// block quotes, GFM tables, nested bullet / ordered / task lists, paragraphs.
/// Inline syntax is left to the `inline` closure. Deliberately forgiving: it
/// runs on every streamed chunk, so an unclosed fence or a half-typed table
/// must still produce sensible blocks.
enum MarkdownParser {
    /// `keepsIndentation` keeps each paragraph line's leading whitespace, for
    /// text a person typed (a pasted stack trace reads by its indentation);
    /// CommonMark strips it, which suits what agents write.
    static func parse<Inline>(
        _ raw: String,
        keepsIndentation: Bool = false,
        inline: (String) -> Inline
    ) -> [MarkdownNode<Inline>] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parseLines(lines[...], keepsIndentation: keepsIndentation, inline: inline)
    }

    private static func parseLines<Inline>(
        _ lines: ArraySlice<String>,
        keepsIndentation: Bool,
        inline: (String) -> Inline
    ) -> [MarkdownNode<Inline>] {
        var blocks: [MarkdownNode<Inline>] = []
        var i = lines.startIndex

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if let fence = Fence(line: line) {
                i += 1
                var body: [String] = []
                while i < lines.endIndex {
                    if fence.closes(lines[i]) { i += 1; break }
                    body.append(fence.stripIndent(lines[i]))
                    i += 1
                }
                let code = body.joined(separator: "\n")
                if fence.language?.lowercased() == "math" {
                    blocks.append(.math(latex: code, source: code))
                } else {
                    blocks.append(.code(language: fence.language, code: code))
                }
                continue
            }

            if let formula = displayFormula(in: lines, from: i) {
                blocks.append(.math(latex: formula.latex, source: formula.source))
                i = formula.nextIndex
                continue
            }

            if let (level, text) = atxHeading(trimmed) {
                blocks.append(.heading(level: level, inline(text)))
                i += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }

            if quoteContent(line) != nil {
                var quoted: [String] = []
                while i < lines.endIndex, let content = quoteContent(lines[i]) {
                    quoted.append(content)
                    i += 1
                }
                blocks.append(.quote(parseLines(quoted[...], keepsIndentation: keepsIndentation, inline: inline)))
                continue
            }

            if i + 1 < lines.endIndex, line.contains("|"), let alignments = tableAlignments(lines[i + 1]) {
                let header = tableCells(line)
                let columns = header.count
                i += 2
                var rows: [[String]] = []
                while i < lines.endIndex, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(padded(tableCells(lines[i]), to: columns))
                    i += 1
                }
                blocks.append(.table(MarkdownTable(
                    header: header.map(inline),
                    alignments: padded(alignments, to: columns, with: .leading),
                    rows: rows.map { $0.map(inline) }
                )))
                continue
            }

            if ListLine(line) != nil {
                let (items, next) = parseList(lines, from: i)
                blocks.append(.list(items.map {
                    MarkdownListItem(level: $0.level, marker: $0.marker, content: inline($0.text))
                }))
                i = next
                continue
            }

            // Paragraph: gather until a blank line or the start of another block.
            // A `===` / `---` underline turns it into a setext heading.
            func kept(_ line: String, trimmed: String) -> String {
                keepsIndentation ? String(line.prefix(while: { $0 == " " || $0 == "\t" })) + trimmed : trimmed
            }
            var paragraph: [String] = [kept(line, trimmed: trimmed)]
            i += 1
            var setextLevel: Int?
            while i < lines.endIndex {
                let next = lines[i]
                let t = next.trimmingCharacters(in: .whitespaces)
                if let level = setextUnderline(t) { setextLevel = level; i += 1; break }
                if interruptsParagraph(next, lines: lines, at: i) { break }
                paragraph.append(kept(next, trimmed: t))
                i += 1
            }
            let text = paragraph.joined(separator: "\n")
            if let setextLevel {
                blocks.append(.heading(level: setextLevel, inline(text.trimmingCharacters(in: .whitespaces))))
            } else {
                blocks.append(.paragraph(inline(text)))
            }
        }
        return blocks
    }

    private static func interruptsParagraph(_ line: String, lines: ArraySlice<String>, at i: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || Fence(line: line) != nil || atxHeading(trimmed) != nil
            || isRule(trimmed) || quoteContent(line) != nil {
            return true
        }
        if displayFormula(in: lines, from: i) != nil { return true }
        if i + 1 < lines.endIndex, line.contains("|"), tableAlignments(lines[i + 1]) != nil { return true }
        // CommonMark: an ordered list interrupts a paragraph only when it starts
        // at 1, so "…in 2019.\n2020 was…" stays prose.
        if let item = ListLine(line) {
            if case .ordered(let n, _) = item.kind { return n == 1 }
            return true
        }
        return false
    }

    // MARK: Lists

    private struct FlatItem {
        var level: Int
        var marker: MarkdownListMarker
        var text: String
    }

    /// Parses a run of list items starting at `start`. Returns the items and the
    /// index of the first line after the list.
    private static func parseList(_ lines: ArraySlice<String>, from start: Int) -> ([FlatItem], Int) {
        var items: [FlatItem] = []
        // Indentation of each open nesting level, outermost first.
        var indents: [Int] = []
        // The next number per level for ordered items, CommonMark-style.
        var counters: [Int: Int] = [:]
        var i = start

        func level(forIndent indent: Int) -> Int {
            guard !indents.isEmpty else { indents = [indent]; return 0 }
            // Close the levels deeper than this item (±1 column of slack, so a
            // 3-space "1. " indent and a 2-space "- " indent both nest).
            while indents.count > 1, indent < indents[indents.count - 1] - 1 { indents.removeLast() }
            if indent >= indents[indents.count - 1] + 2 {
                indents.append(indent)
            } else if indents.count == 1 {
                indents[0] = min(indents[0], indent)
            }
            return indents.count - 1
        }

        var afterBlank = false
        while i < lines.endIndex {
            let line = lines[i]
            if let item = ListLine(line) {
                afterBlank = false
                let depth = level(forIndent: item.indent)
                counters = counters.filter { $0.key <= depth }
                let marker: MarkdownListMarker
                switch item.kind {
                case .bullet(let checked):
                    counters[depth] = nil
                    marker = checked.map { .task(checked: $0) } ?? .bullet
                case .ordered(let n, _):
                    let number = counters[depth] ?? n
                    counters[depth] = number + 1
                    marker = .ordered(number)
                }
                items.append(FlatItem(level: depth, marker: marker, text: item.content))
                i += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A blank line continues the list only if more of it follows:
                // another item, or an indented continuation of the current one.
                var j = i + 1
                while j < lines.endIndex, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.endIndex else { break }
                let nextLine = lines[j]
                if ListLine(nextLine) != nil
                    || (leadingColumns(nextLine) >= 2 && Fence(line: nextLine) == nil && !items.isEmpty) {
                    i = j
                    afterBlank = true
                    continue
                }
                break
            }

            // A fence or another block ends the list; the code block renders
            // after it rather than inside the item.
            if Fence(line: line) != nil || atxHeading(trimmed) != nil || isRule(trimmed)
                || quoteContent(line) != nil {
                break
            }

            // Continuation line (indented or lazy): part of the current item, as
            // a new paragraph when a blank line separated it.
            guard !items.isEmpty else { break }
            items[items.count - 1].text += (afterBlank ? "\n\n" : "\n") + trimmed
            afterBlank = false
            i += 1
        }
        return (items, i)
    }

    /// A line that starts a list item.
    private struct ListLine {
        enum Kind {
            /// `checked` is non-nil for a task item (`- [ ]` / `- [x]`).
            case bullet(checked: Bool?)
            case ordered(Int, delimiter: Character)
        }

        let indent: Int
        let kind: Kind
        let content: String

        init?(_ line: String) {
            let indent = MarkdownParser.leadingColumns(line)
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = body.first else { return nil }

            if first == "-" || first == "*" || first == "+" {
                let rest = body.dropFirst()
                // "-" alone (an empty item being typed) or "- text"; "--" or "-x" is prose.
                guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
                var content = String(rest.drop(while: { $0 == " " || $0 == "\t" }))
                var checked: Bool?
                for (box, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where content.hasPrefix(box) {
                    checked = value
                    content = String(content.dropFirst(box.count))
                }
                if checked == nil, ["[ ]", "[x]", "[X]"].contains(content) {
                    checked = content != "[ ]"
                    content = ""
                }
                self.indent = indent
                self.kind = .bullet(checked: checked)
                self.content = content
                return
            }

            let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
            let rest = afterDigits.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            self.indent = indent
            self.kind = .ordered(number, delimiter: delimiter)
            self.content = String(rest.drop(while: { $0 == " " || $0 == "\t" }))
        }
    }

    // MARK: Line classifiers

    /// Leading indentation in columns, with tabs to the next multiple of 4.
    static func leadingColumns(_ line: String) -> Int {
        var columns = 0
        for ch in line {
            if ch == " " { columns += 1 } else if ch == "\t" { columns += 4 - columns % 4 } else { break }
        }
        return columns
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let indent: Int
        let language: String?

        init?(line: String) {
            let indent = MarkdownParser.leadingColumns(line)
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = body.first, first == "`" || first == "~" else { return nil }
            let run = body.prefix(while: { $0 == first })
            guard run.count >= 3 else { return nil }
            let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string may not contain backticks
            // (```` ```foo``` ```` on one line is inline code, not a fence).
            if first == "`", info.contains("`") { return nil }
            self.marker = first
            self.length = run.count
            self.indent = indent
            let language = info.split(separator: " ").first.map(String.init) ?? ""
            self.language = language.isEmpty ? nil : language
        }

        func closes(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.count >= length && t.allSatisfy { $0 == marker }
        }

        /// Removes up to the fence's own indentation, so code inside a list item
        /// isn't shifted right by the item's indent.
        func stripIndent(_ line: String) -> String {
            var remaining = indent
            var index = line.startIndex
            while remaining > 0, index < line.endIndex, line[index] == " " {
                remaining -= 1
                index = line.index(after: index)
            }
            return String(line[index...])
        }
    }

    private struct DisplayFormula {
        let latex: String
        let source: String
        let nextIndex: Int
    }

    /// Recognizes only isolated display delimiters. Keeping this ahead of table
    /// and list classification prevents matrix rows from being interpreted as
    /// Markdown structure, while an unclosed streamed formula stays literal.
    private static func displayFormula(in lines: ArraySlice<String>, from index: Int) -> DisplayFormula? {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        let sameLine: (open: String, close: String)? = {
            if trimmed.hasPrefix("$$") { return ("$$", "$$") }
            if trimmed.hasPrefix("\\[") { return ("\\[", "\\]") }
            return nil
        }()
        if let sameLine, trimmed.hasSuffix(sameLine.close), trimmed.count > sameLine.open.count + sameLine.close.count {
            let start = trimmed.index(trimmed.startIndex, offsetBy: sameLine.open.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -sameLine.close.count)
            let latex = String(trimmed[start..<end])
            guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DisplayFormula(latex: latex, source: trimmed, nextIndex: index + 1)
        }

        let close: String
        switch trimmed {
        case "$$": close = "$$"
        case "\\[": close = "\\]"
        default: return nil
        }

        var body: [String] = []
        var cursor = index + 1
        while cursor < lines.endIndex {
            if lines[cursor].trimmingCharacters(in: .whitespaces) == close {
                let latex = body.joined(separator: "\n")
                guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let source = lines[index...cursor].joined(separator: "\n")
                return DisplayFormula(latex: latex, source: source, nextIndex: cursor + 1)
            }
            body.append(lines[cursor])
            cursor += 1
        }
        return nil
    }

    private static func atxHeading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing sequence: "## Title ##".
        if let closing = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (hashes.count, text)
    }

    private static func setextUnderline(_ trimmed: String) -> Int? {
        if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// The content of a `>` quote line (one `>` and one optional space removed),
    /// or nil when the line isn't quoted.
    private static func quoteContent(_ line: String) -> String? {
        guard leadingColumns(line) <= 3 else { return nil }
        let body = line.drop(while: { $0 == " " })
        guard body.first == ">" else { return nil }
        var content = body.dropFirst()
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }

    // MARK: Tables

    /// Column alignments when `line` is a GFM delimiter row (`| --- | :-: |`).
    private static func tableAlignments(_ line: String) -> [MarkdownTableAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.contains(":"),
              t.allSatisfy({ "|-: \t".contains($0) }) else { return nil }
        let cells = tableCells(t)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            guard cell.contains("-"), cell.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// Splits a table row on unescaped pipes; `\|` stays a literal pipe.
    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in t {
            if escaped {
                current.append(ch == "|" ? "|" : "\\")
                if ch != "|" { current.append(ch) }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func padded<T>(_ values: [T], to count: Int, with filler: T) -> [T] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: filler, count: count - values.count)
    }

    private static func padded(_ cells: [String], to count: Int) -> [String] {
        padded(cells, to: count, with: "")
    }
}
