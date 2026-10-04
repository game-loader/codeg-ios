import Foundation

/// Protects native LaTeX spans from Foundation Markdown while retaining the
/// exact source needed for copy and for a raw-text fallback.
public enum MarkdownMath {
    public struct Formula: Equatable, Hashable {
        public let latex: String
        public let source: String
        public let display: Bool

        public init(latex: String, source: String, display: Bool) {
            self.latex = latex
            self.source = source
            self.display = display
        }
    }

    /// Replaces closed `\(...\)`, `\[...\]`, and `$$...$$` spans with unique
    /// alphanumeric markers. Single-dollar math is intentionally unsupported.
    /// Code spans, link destinations, escaped delimiters, and unclosed spans
    /// remain byte-for-byte literal.
    public static func maskInline(_ raw: String) -> (text: String, formulas: [String: Formula]) {
        let characters = Array(raw)
        var output = String()
        var formulas: [String: Formula] = [:]
        var index = 0
        var markerIndex = 0

        func append(_ start: Int, _ end: Int) {
            guard start < end else { return }
            output.append(contentsOf: characters[start..<end])
        }

        while index < characters.count {
            if characters[index] == "`", !isEscaped(in: characters, at: index) {
                let run = countRun(of: "`", in: characters, from: index)
                if let end = codeSpanEnd(in: characters, from: index + run, runLength: run) {
                    append(index, end)
                    index = end
                } else {
                    append(index, characters.count)
                    break
                }
                continue
            }

            if characters[index] == "]",
               let end = linkDestinationEnd(in: characters, after: index) {
                append(index, end)
                index = end
                continue
            }

            if let match = formulaAt(in: characters, from: index) {
                var marker: String
                repeat {
                    marker = "CODEGMATHTOKEN\(markerIndex)X"
                    markerIndex += 1
                } while raw.contains(marker) || formulas[marker] != nil

                let source = String(characters[index..<match.end])
                formulas[marker] = Formula(latex: match.latex, source: source, display: match.display)
                output.append(marker)
                index = match.end
                continue
            }

            output.append(characters[index])
            index += 1
        }

        return (output, formulas)
    }

    private struct Match {
        let end: Int
        let latex: String
        let display: Bool
    }

    private static func formulaAt(in characters: [Character], from index: Int) -> Match? {
        guard index < characters.count, !isEscaped(in: characters, at: index) else { return nil }

        if characters[index] == "\\", index + 1 < characters.count {
            let opener = characters[index + 1]
            let closer: Character
            switch opener {
            case "(": closer = ")"
            case "[": closer = "]"
            default: return nil
            }

            var cursor = index + 2
            while cursor + 1 < characters.count {
                if characters[cursor] == "\\", characters[cursor + 1] == closer,
                   !isEscaped(in: characters, at: cursor) {
                    let latex = String(characters[(index + 2)..<cursor])
                    guard !latex.isEmpty else { return nil }
                    return Match(end: cursor + 2, latex: latex, display: opener == "[")
                }
                cursor += 1
            }
            return nil
        }

        guard characters[index] == "$", index + 1 < characters.count,
              characters[index + 1] == "$" else { return nil }

        var cursor = index + 2
        while cursor + 1 < characters.count {
            if characters[cursor] == "$", characters[cursor + 1] == "$",
               !isEscaped(in: characters, at: cursor) {
                let latex = String(characters[(index + 2)..<cursor])
                guard !latex.isEmpty else { return nil }
                return Match(end: cursor + 2, latex: latex, display: true)
            }
            cursor += 1
        }
        return nil
    }

    private static func countRun(of character: Character, in characters: [Character], from index: Int) -> Int {
        var end = index
        while end < characters.count, characters[end] == character { end += 1 }
        return end - index
    }

    private static func codeSpanEnd(in characters: [Character], from start: Int, runLength: Int) -> Int? {
        guard start <= characters.count else { return nil }
        var cursor = start
        while cursor + runLength <= characters.count {
            let candidateLength = countRun(of: "`", in: characters, from: cursor)
            if candidateLength == runLength {
                return cursor + runLength
            }
            cursor += max(1, candidateLength)
        }
        return nil
    }

    /// A link destination is opaque to the scanner, including nested and
    /// escaped parentheses. The label itself has already been scanned.
    private static func linkDestinationEnd(in characters: [Character], after closeBracket: Int) -> Int? {
        var cursor = closeBracket + 1
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" || characters[cursor] == "\n" {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "(" else { return nil }

        var depth = 1
        cursor += 1
        while cursor < characters.count {
            if characters[cursor] == "\\", cursor + 1 < characters.count {
                cursor += 2
                continue
            }
            if characters[cursor] == "(" {
                depth += 1
            } else if characters[cursor] == ")" {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return characters.count
    }

    private static func isEscaped(in characters: [Character], at index: Int) -> Bool {
        var slashCount = 0
        var cursor = index - 1
        while cursor >= 0, characters[cursor] == "\\" {
            slashCount += 1
            cursor -= 1
        }
        return slashCount % 2 == 1
    }
}
