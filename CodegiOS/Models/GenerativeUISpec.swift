import Foundation

/// A deliberately closed, read-only subset of Codeg's json-render 0.21 catalog.
/// No UI, JavaScript, actions, networking, or dependency on the app's AnyJSON.
struct GenerativeUISpec {
    enum Limits {
        static let inputBytes = 262_144
        static let patches = 1_024
        static let jsonDepth = 48
        static let jsonNodes = 32_768
        static let traversal = 262_144
        static let elements = 256
        static let renderDepth = 24
        static let renderNodes = 512
        static let renderWork = 8_192
        static let renderTextBytes = 524_288
        static let tableCells = 2_048
        static let chartRows = 128
        static let chartSeries = 8
        static let chartPoints = 512
        static let pieSlices = 32
    }

    let root: String
    let elements: [String: Element]

    struct Element {
        let type: String
        let props: [String: Value]
        let children: [String]
        let chart: Chart?
        let textBytes: Int
        var work: Int {
            if let chart { return max(1, chart.points.count) }
            if type == "Table" {
                return (props["columns"]?.array?.count ?? 0) * ((props["rows"]?.array?.count ?? 0) + 1)
            }
            return 1
        }
        func text(_ key: String, default fallback: String = "") -> String { props[key]?.string ?? fallback }
        func flag(_ key: String) -> Bool { props[key]?.bool == true }
    }

    struct Chart {
        struct Series {
            let id: String
            let label: String
        }
        struct Point: Identifiable {
            let id: Int
            let category: String
            let series: String
            let value: Double
        }
        let type: String
        let points: [Point]
        let series: [Series]
        let categoryLabel: String
        let height: Double
        let stacked: Bool
        let horizontal: Bool
        let labels: Bool
        let dots: Bool
        let legend: Bool
        let curve: String
        let donut: Bool
        let centerLabel: String?
        var total: Double { points.reduce(0) { $0 + $1.value } }
    }

    indirect enum Value: Equatable {
        case object([String: Value]), array([Value]), string(String), number(Double), bool(Bool), null
        var object: [String: Value]? { if case .object(let x) = self { return x }; return nil }
        var array: [Value]? { if case .array(let x) = self { return x }; return nil }
        var string: String? { if case .string(let x) = self { return x }; return nil }
        var number: Double? { if case .number(let x) = self { return x }; return nil }
        var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    }

    /// `nil` means the caller must preserve the *whole* original CodeBlockView.
    /// Only syntactically unfinished JSON at the final nonempty streaming line
    /// may be skipped; invalid operations and complete malformed JSON fail closed.
    static func parse(_ source: String, streaming: Bool = false) -> GenerativeUISpec? {
        guard source.utf8.count <= Limits.inputBytes else { return nil }
        do { return try Compiler().compile(source, streaming: streaming) }
        catch { return nil }
    }

    /// All navigation still passes through the session's environment OpenURL.
    /// Relative/server file paths are kept relative; no URL rewriting here.
    static func linkURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.contains("\\"), let url = URL(string: raw) else { return nil }
        switch url.scheme?.lowercased() {
        case "https", "http":
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        case "mailto":
            guard !url.path.isEmpty else { return nil }
        case "file":
            guard url.host == nil || url.host == "" || url.host == "localhost",
                  !url.path.isEmpty, url.user == nil else { return nil }
        case "codeg":
            guard url.host?.lowercased() == "session", url.user == nil, url.port == nil,
                  Int(url.lastPathComponent) != nil else { return nil }
        case nil:
            guard url.host == nil, !raw.hasPrefix("//"), !url.path.isEmpty,
                  !url.path.contains(":"), url.path.contains("/") || !(url.path as NSString).pathExtension.isEmpty
            else { return nil }
        default: return nil
        }
        return url
    }
}

private extension GenerativeUISpec {
    enum Invalid: Error { case source }
    static let forbidden: Set<String> = ["__proto__", "prototype", "constructor"]

    /// A strict JSON prefix reader distinguishes incomplete streaming JSON
    /// from already malformed JSON. Depth is checked before recursion, duplicate
    /// keys are rejected, and Foundation only decodes individual string tokens.
    struct JSONReader {
        enum Failure: Error { case incomplete, invalid, limit }
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        var next: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func whitespace() {
            while let b = next, [9, 10, 13, 32].contains(b) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) throws {
            guard let b = next else { throw Failure.incomplete }
            guard b == byte else { throw Failure.invalid }
            index += 1
        }
        mutating func read() throws -> Value {
            whitespace()
            guard next == 123 else { throw Failure.invalid }
            let value = try value(depth: 0)
            whitespace()
            guard next == nil else { throw Failure.invalid }
            return value
        }
        mutating func value(depth: Int) throws -> Value {
            nodes += 1
            guard nodes <= Limits.jsonNodes, depth < Limits.jsonDepth else { throw Failure.limit }
            whitespace()
            guard let b = next else { throw Failure.incomplete }
            switch b {
            case 123:
                index += 1
                var object: [String: Value] = [:]
                whitespace()
                if next == 125 { index += 1; return .object(object) }
                while true {
                    whitespace()
                    let key = try string()
                    guard object[key] == nil else { throw Failure.invalid }
                    whitespace()
                    try consume(58)
                    object[key] = try value(depth: depth + 1)
                    whitespace()
                    if next == 125 { index += 1; return .object(object) }
                    try consume(44)
                }
            case 91:
                index += 1
                var array: [Value] = []
                whitespace()
                if next == 93 { index += 1; return .array(array) }
                while true {
                    array.append(try value(depth: depth + 1))
                    whitespace()
                    if next == 93 { index += 1; return .array(array) }
                    try consume(44)
                }
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57: return .number(try number())
            default: throw Failure.invalid
            }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { try consume(byte) }
        }
        mutating func string() throws -> String {
            let start = index
            try consume(34)
            while let byte = next {
                index += 1
                if byte == 34 {
                    guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    else { throw Failure.invalid }
                    return text
                }
                guard byte >= 32 else { throw Failure.invalid }
                if byte == 92 {
                    guard let escape = next else { throw Failure.incomplete }
                    index += 1
                    if escape == 117 {
                        for _ in 0..<4 {
                            guard let hex = next else { throw Failure.incomplete }
                            guard (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex)
                            else { throw Failure.invalid }
                            index += 1
                        }
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) { throw Failure.invalid }
                }
            }
            throw Failure.incomplete
        }
        mutating func digits() throws {
            guard let b = next else { throw Failure.incomplete }
            guard (48...57).contains(b) else { throw Failure.invalid }
            while let b = next, (48...57).contains(b) { index += 1 }
        }
        mutating func number() throws -> Double {
            let start = index
            if next == 45 { index += 1 }
            guard let b = next else { throw Failure.incomplete }
            if b == 48 {
                index += 1
                if let b = next, (48...57).contains(b) { throw Failure.invalid }
            } else { try digits() }
            if next == 46 { index += 1; try digits() }
            if next == 69 || next == 101 {
                index += 1
                if next == 43 || next == 45 { index += 1 }
                try digits()
            }
            guard let result = Double(String(decoding: bytes[start..<index], as: UTF8.self)), result.isFinite
            else { throw Failure.invalid }
            return result
        }
    }

    final class Compiler {
        var visited = 0
        var decodedNodes = 0
        func spend(_ amount: Int = 1) throws {
            visited += amount
            guard visited <= Limits.traversal else { throw Invalid.source }
        }

        func compile(_ source: String, streaming: Bool) throws -> GenerativeUISpec {
            // Normalize CRLF first: it is one grapheme, including in Linux's
            // Foundation components(separatedBy:) implementation.
            let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw Invalid.source }
            var document: Value = .object(["root": .string(""), "elements": .object([:]), "state": .object([:])])
            var count = 0
            for index in lines.indices {
                let line = String(lines[index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                let value: Value
                do {
                    var reader = JSONReader(bytes: Array(line.utf8))
                    value = try reader.read()
                } catch JSONReader.Failure.incomplete {
                    if streaming && index == last && count > 0 { break }
                    throw Invalid.source
                }
                try inspect(value, depth: 0, decoding: true)
                guard let patch = value.object, let op = patch["op"]?.string,
                      ["add", "replace", "remove"].contains(op), let path = patch["path"]?.string,
                      Set(patch.keys).isSubset(of: ["op", "path", "value"]),
                      op == "remove" || patch["value"] != nil else { throw Invalid.source }
                let tokens = try pointer(path)
                guard tokens.isEmpty || ["root", "elements", "state"].contains(tokens[0]) else { throw Invalid.source }
                count += 1
                guard count <= Limits.patches else { throw Invalid.source }
                document = try apply(document, tokens: tokens[...], op: op, value: patch["value"])
                // Limits hold after every mutation, including temporary documents.
                try inspect(document, depth: 0, decoding: false)
            }
            guard count > 0, let object = document.object,
                  Set(object.keys).isSubset(of: ["root", "elements", "state"]),
                  let root = object["root"]?.string, !root.isEmpty,
                  let rawElements = object["elements"]?.object, exactValue(root, in: rawElements) != nil,
                  rawElements.count <= Limits.elements else { throw Invalid.source }
            let state = object["state"] ?? .object([:])
            guard state.object != nil else { throw Invalid.source }
            var elements: [String: Element] = [:]
            for (id, raw) in rawElements {
                guard !id.isEmpty, let element = raw.object,
                      Set(element.keys).isSubset(of: ["type", "props", "children", "slots"]),
                      let type = element["type"]?.string else { throw Invalid.source }
                // Named slots have no faithful representation in this subset.
                if let slots = element["slots"], slots != .null, slots != .object([:]) { throw Invalid.source }
                let rawProps = element["props"] ?? .object([:])
                guard let props = try resolve(rawProps, state: state).object else { throw Invalid.source }
                let childrenValue = element["children"] ?? .array([])
                guard let childValues = childrenValue.array else { throw Invalid.source }
                let children = try childValues.map { value -> String in
                    guard let id = value.string, exactValue(id, in: rawElements) != nil else { throw Invalid.source }
                    return id
                }
                let chart = try validate(type, props: props, children: children)
                elements[id] = Element(type: type, props: props, children: children, chart: chart,
                                       textBytes: try textBytes(.object(props)))
            }
            // Validate every element, including disconnected fragments, so a later
            // root replacement cannot expose previously ignored features/cycles.
            var done: Set<String> = []
            for id in elements.keys { try graph(id, elements: elements, path: [], done: &done, depth: 0) }
            var nodes = 0
            var work = 0
            var textBytes = 0
            try expansion(root, elements: elements, depth: 0, nodes: &nodes, work: &work, textBytes: &textBytes)
            return GenerativeUISpec(root: root, elements: elements)
        }

        func inspect(_ value: Value, depth: Int, decoding: Bool) throws {
            try spend()
            guard depth <= Limits.jsonDepth else { throw Invalid.source }
            if decoding {
                decodedNodes += 1
                guard decodedNodes <= Limits.jsonNodes else { throw Invalid.source }
            }
            switch value {
            case .object(let object):
                for (key, child) in object {
                    guard !GenerativeUISpec.forbidden.contains(key) else { throw Invalid.source }
                    try inspect(child, depth: depth + 1, decoding: decoding)
                }
            case .array(let array):
                for child in array { try inspect(child, depth: depth + 1, decoding: decoding) }
            case .string(let text):
                guard text.utf8.count <= 16_384 else { throw Invalid.source }
            default: break
            }
        }

        func pointer(_ path: String) throws -> [String] {
            if path.isEmpty { return [] }
            guard path.utf8.first == 47, path.utf8.count <= 4_096 else { throw Invalid.source }
            // RFC6901 escapes are ASCII bytes, not extended grapheme clusters.
            // A combining mark next to '/' or '~1' must stay part of the key.
            let raw = path.utf8.dropFirst().split(separator: 47, omittingEmptySubsequences: false)
            guard raw.count <= Limits.jsonDepth else { throw Invalid.source }
            return try raw.map { token in
                var bytes: [UInt8] = []
                var escaped = false
                for byte in token {
                    if escaped {
                        guard byte == 48 || byte == 49 else { throw Invalid.source }
                        bytes.append(byte == 48 ? 126 : 47)
                        escaped = false
                    } else if byte == 126 { escaped = true }
                    else { bytes.append(byte) }
                }
                let output = String(decoding: bytes, as: UTF8.self)
                guard !escaped, !GenerativeUISpec.forbidden.contains(output) else { throw Invalid.source }
                return output
            }
        }

        /// Swift String equality normalizes Unicode; JSON object lookup doesn't.
        /// Fail closed if a pointer only matches after canonical normalization.
        func exactValue(_ key: String, in object: [String: Value]) -> Value? {
            guard let index = object.index(forKey: key), object[index].key.utf8.elementsEqual(key.utf8) else { return nil }
            return object[index].value
        }

        func textBytes(_ value: Value) throws -> Int {
            try spend()
            switch value {
            case .string(let text): return text.utf8.count
            case .array(let values): return try values.reduce(0) { try $0 + textBytes($1) }
            case .object(let values): return try values.values.reduce(0) { try $0 + textBytes($1) }
            default: return 0
            }
        }

        func arrayIndex(_ token: String, count: Int, append: Bool) throws -> Int {
            if token == "-", append { return count }
            guard !token.isEmpty, token == "0" || token.first != "0",
                  token.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let index = Int(token),
                  index < count || (append && index == count) else { throw Invalid.source }
            return index
        }

        func apply(_ current: Value, tokens: ArraySlice<String>, op: String, value: Value?) throws -> Value {
            try spend()
            guard let token = tokens.first else {
                guard op != "remove", let value else { throw Invalid.source }
                return value
            }
            let rest = tokens.dropFirst()
            switch current {
            case .object(var object):
                if object[token] != nil, exactValue(token, in: object) == nil { throw Invalid.source }
                if rest.isEmpty {
                    guard op == "add" || object[token] != nil else { throw Invalid.source }
                    if op == "remove" { object.removeValue(forKey: token) }
                    else { object[token] = value }
                } else {
                    guard let child = exactValue(token, in: object) else { throw Invalid.source }
                    object[token] = try apply(child, tokens: rest, op: op, value: value)
                }
                return .object(object)
            case .array(var array):
                let index = try arrayIndex(token, count: array.count, append: rest.isEmpty && op == "add")
                if rest.isEmpty {
                    if op == "remove" { array.remove(at: index) }
                    else if let value {
                        if op == "add" { array.insert(value, at: index) }
                        else { array[index] = value }
                    } else { throw Invalid.source }
                } else { array[index] = try apply(array[index], tokens: rest, op: op, value: value) }
                return .array(array)
            default: throw Invalid.source
            }
        }

        func lookup(_ state: Value, path: String) throws -> Value {
            var value = state
            for token in try pointer(path) {
                try spend()
                if let object = value.object, let child = exactValue(token, in: object) { value = child }
                else if let array = value.array { value = array[try arrayIndex(token, count: array.count, append: false)] }
                else { throw Invalid.source }
            }
            return value
        }

        func resolve(_ value: Value, state: Value, bindings: Bool = true, depth: Int = 0) throws -> Value {
            try spend()
            guard depth <= Limits.jsonDepth else { throw Invalid.source }
            switch value {
            case .object(let object):
                if bindings, object.count == 1, let path = object["$state"]?.string {
                    // State values are data, never recursively evaluated expressions.
                    return try resolve(lookup(state, path: path), state: state, bindings: false, depth: depth + 1)
                }
                guard !object.keys.contains(where: { $0.hasPrefix("$") }) else { throw Invalid.source }
                return .object(try object.mapValues { try resolve($0, state: state, bindings: bindings, depth: depth + 1) })
            case .array(let array):
                return .array(try array.map { try resolve($0, state: state, bindings: bindings, depth: depth + 1) })
            default: return value
            }
        }

        func graph(_ id: String, elements: [String: Element], path: Set<String>, done: inout Set<String>, depth: Int) throws {
            try spend()
            guard depth < Limits.renderDepth, !path.contains(id), let element = elements[id] else { throw Invalid.source }
            if done.contains(id) { return }
            var path = path
            path.insert(id)
            for child in element.children { try graph(child, elements: elements, path: path, done: &done, depth: depth + 1) }
            done.insert(id)
        }

        func expansion(_ id: String, elements: [String: Element], depth: Int, nodes: inout Int, work: inout Int, textBytes: inout Int) throws {
            try spend()
            guard depth < Limits.renderDepth, let element = elements[id] else { throw Invalid.source }
            nodes += 1
            work += element.work
            textBytes += element.textBytes
            guard nodes <= Limits.renderNodes, work <= Limits.renderWork, textBytes <= Limits.renderTextBytes else { throw Invalid.source }
            for child in element.children {
                try expansion(child, elements: elements, depth: depth + 1, nodes: &nodes, work: &work, textBytes: &textBytes)
            }
        }
    }
}

private extension GenerativeUISpec.Compiler {
    typealias Value = GenerativeUISpec.Value
    typealias Chart = GenerativeUISpec.Chart
    typealias Invalid = GenerativeUISpec.Invalid
    typealias Limits = GenerativeUISpec.Limits

    func validate(_ type: String, props p: [String: Value], children: [String]) throws -> Chart? {
        let allowed: [String: Set<String>] = [
            "Card": ["title", "description", "maxWidth", "centered", "className"],
            "Stack": ["direction", "gap", "align", "justify", "className"],
            "Grid": ["columns", "gap", "className"],
            "Heading": ["text", "level"], "Text": ["text", "variant"],
            "Badge": ["text", "variant"], "Separator": ["orientation"],
            "Link": ["label", "href"], "Table": ["columns", "rows", "caption"],
            "BarChart": ["data", "xKey", "series", "stacked", "horizontal", "labels", "legend", "height"],
            "LineChart": ["data", "xKey", "series", "curve", "dots", "labels", "legend", "height"],
            "AreaChart": ["data", "xKey", "series", "stacked", "curve", "legend", "height"],
            "PieChart": ["data", "nameKey", "valueKey", "donut", "centerLabel", "labels", "legend", "height"]
        ]
        guard let keys = allowed[type], Set(p.keys).isSubset(of: keys),
              children.isEmpty || ["Card", "Stack", "Grid"].contains(type) else { throw Invalid.source }
        if let css = p["className"], css != .null, css != .string("") { throw Invalid.source }
        switch type {
        case "Card":
            try optionalStrings(p, ["title", "description"])
            try choice(p, "maxWidth", ["sm", "md", "lg", "full"])
            try booleans(p, ["centered"])
        case "Stack":
            try choice(p, "direction", ["horizontal", "vertical"])
            try choice(p, "gap", ["none", "sm", "md", "lg", "xl"])
            // Other flex justification/stretch modes require a wrapping layout
            // with different semantics; preserve source instead of approximating.
            try choice(p, "align", ["start", "center", "end"])
            try choice(p, "justify", ["start"])
        case "Grid":
            try choice(p, "gap", ["sm", "md", "lg", "xl"])
            if let value = p["columns"], value != .null {
                guard let n = value.number, n >= 1, n <= 6, n.rounded() == n else { throw Invalid.source }
            }
        case "Heading":
            try requiredStrings(p, ["text"])
            try choice(p, "level", ["h1", "h2", "h3", "h4"])
        case "Text":
            try requiredStrings(p, ["text"])
            try choice(p, "variant", ["body", "caption", "muted", "lead", "code"])
        case "Badge":
            try requiredStrings(p, ["text"])
            try choice(p, "variant", ["default", "secondary", "destructive", "outline"])
        case "Separator": try choice(p, "orientation", ["horizontal", "vertical"])
        case "Link":
            try requiredStrings(p, ["label", "href"])
            guard GenerativeUISpec.linkURL(p["href"]!.string!) != nil else { throw Invalid.source }
        case "Table":
            try optionalStrings(p, ["caption"])
            guard let columns = p["columns"]?.array, !columns.isEmpty, columns.count <= 16,
                  columns.allSatisfy({ $0.string != nil }), let rows = p["rows"]?.array,
                  columns.count * (rows.count + 1) <= Limits.tableCells else { throw Invalid.source }
            for row in rows {
                guard let cells = row.array, cells.count == columns.count,
                      cells.allSatisfy({ $0.string != nil }) else { throw Invalid.source }
            }
        default: return try chart(type, props: p)
        }
        return nil
    }

    func requiredStrings(_ p: [String: Value], _ keys: [String]) throws {
        guard keys.allSatisfy({ p[$0]?.string != nil }) else { throw Invalid.source }
    }
    func optionalStrings(_ p: [String: Value], _ keys: [String]) throws {
        for key in keys { if let value = p[key], value != .null, value.string == nil { throw Invalid.source } }
    }
    func booleans(_ p: [String: Value], _ keys: [String]) throws {
        for key in keys { if let value = p[key], value != .null, value.bool == nil { throw Invalid.source } }
    }
    func choice(_ p: [String: Value], _ key: String, _ values: Set<String>) throws {
        if let value = p[key], value != .null {
            guard let text = value.string, values.contains(text) else { throw Invalid.source }
        }
    }

    /// Match chart-data.ts's numbers and numeric strings for the supported
    /// decimal subset. Other JS numeric coercions and gaps preserve source.
    func chartNumber(_ value: Value?) throws -> Double {
        let number: Double?
        if let n = value?.number { number = n }
        else if let text = value?.string {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: #"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
            else { throw Invalid.source }
            number = Double(trimmed)
        } else { number = nil }
        guard let number, number.isFinite, abs(number) <= 1_000_000_000_000 else { throw Invalid.source }
        return number
    }
    func chartLabel(_ value: Value?) throws -> String {
        if let text = value?.string, !text.isEmpty { return text }
        if let n = value?.number {
            if n.rounded() == n, abs(n) < 1_000_000_000_000_000 { return String(Int64(n)) }
            return String(n)
        }
        if let b = value?.bool { return b ? "true" : "false" }
        throw Invalid.source
    }

    func chart(_ type: String, props p: [String: Value]) throws -> Chart {
        try booleans(p, ["stacked", "horizontal", "labels", "dots", "legend", "donut"])
        var height = 250.0
        if let value = p["height"], value != .null {
            guard let h = value.number, h >= 80, h <= 600 else { throw Invalid.source }
            height = h
        }
        guard let rawRows = p["data"]?.array, !rawRows.isEmpty,
              rawRows.count <= Limits.chartRows else { throw Invalid.source }
        let rows = try rawRows.map { row -> [String: Value] in
            guard let row = row.object else { throw Invalid.source }
            return row
        }
        var points: [Chart.Point] = []
        var series: [Chart.Series] = []
        var categoryLabel = ""
        var seen: Set<String> = []
        var caption: String?
        if type == "PieChart" {
            try requiredStrings(p, ["nameKey", "valueKey"])
            try optionalStrings(p, ["centerLabel"])
            let nameKey = p["nameKey"]!.string!
            let valueKey = p["valueKey"]!.string!
            guard !nameKey.isEmpty, !valueKey.isEmpty, rows.count <= Limits.pieSlices else { throw Invalid.source }
            categoryLabel = nameKey
            caption = p["centerLabel"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            for (index, row) in rows.enumerated() {
                let label = try chartLabel(exactValue(nameKey, in: row))
                let value = try chartNumber(exactValue(valueKey, in: row))
                guard seen.insert(label).inserted, value >= 0 else { throw Invalid.source }
                let id = "slice-\(index)"
                series.append(.init(id: id, label: label))
                points.append(.init(id: index, category: label, series: id, value: value))
            }
            guard points.reduce(0, { $0 + $1.value }) > 0 else { throw Invalid.source }
        } else {
            try requiredStrings(p, ["xKey"])
            categoryLabel = p["xKey"]!.string!
            guard !categoryLabel.isEmpty, let rawSeries = p["series"]?.array, !rawSeries.isEmpty,
                  rawSeries.count <= Limits.chartSeries, rows.count * rawSeries.count <= Limits.chartPoints
            else { throw Invalid.source }
            var fields: [String] = []
            for (index, raw) in rawSeries.enumerated() {
                let field: String
                let label: String
                if let text = raw.string { field = text; label = text }
                else if let object = raw.object, Set(object.keys).isSubset(of: ["key", "label"]),
                        let key = object["key"]?.string {
                    try optionalStrings(object, ["label"])
                    field = key
                    label = object["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? key
                } else { throw Invalid.source }
                guard !field.isEmpty, !fields.contains(field) else { throw Invalid.source }
                fields.append(field)
                series.append(.init(id: "series-\(index)", label: label))
            }
            for row in rows {
                let label = try chartLabel(exactValue(categoryLabel, in: row))
                guard seen.insert(label).inserted else { throw Invalid.source }
                for (index, field) in fields.enumerated() {
                    points.append(.init(id: points.count, category: label, series: series[index].id,
                                        value: try chartNumber(exactValue(field, in: row))))
                }
            }
            if type != "BarChart" {
                // Swift Charts has no Recharts natural spline. Explicit linear
                // and midpoint step curves are represented faithfully.
                guard let curve = p["curve"]?.string, ["linear", "step"].contains(curve) else { throw Invalid.source }
            }
        }
        return Chart(type: type, points: points, series: series, categoryLabel: categoryLabel, height: height,
                     stacked: p["stacked"]?.bool == true, horizontal: p["horizontal"]?.bool == true,
                     labels: p["labels"]?.bool == true, dots: p["dots"]?.bool == true || p["labels"]?.bool == true,
                     legend: p["legend"]?.bool == true, curve: p["curve"]?.string ?? "linear",
                     donut: p["donut"]?.bool == true || caption != nil, centerLabel: caption)
    }
}
