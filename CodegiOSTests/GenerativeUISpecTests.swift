import Foundation
#if !GENERATIVE_UI_PORTABLE
import XCTest
@testable import Codeg

@MainActor
final class GenerativeUISpecTests: XCTestCase {
    func testUpstreamPatches() throws { try GenerativeUISpecCases.upstream() }
    func testPatchOperationsAndEscapedPointers() throws { try GenerativeUISpecCases.pointers() }
    func testStreamingAndMalformedInput() throws { try GenerativeUISpecCases.streaming() }
    func testUnknownAndInteractiveContentPreservesSource() throws { try GenerativeUISpecCases.unsupported() }
    func testGraphsAndExpansionBounds() throws { try GenerativeUISpecCases.graphs() }
    func testInputAndWorkBounds() throws { try GenerativeUISpecCases.bounds() }
    func testChartsUseUpstreamDataProps() throws { try GenerativeUISpecCases.charts() }
    func testSafeLinksKeepRouting() throws { try GenerativeUISpecCases.links() }
}
#endif

/// The portable executable compiles these very same cases against the real
/// Foundation model. No SwiftUI substitute or duplicate parser is involved.
enum GenerativeUISpecCases {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    static func patch(_ path: String, _ value: Any) -> String { patch("add", path, value) }
    static func patch(_ op: String, _ path: String, _ value: Any?) -> String {
        var object: [String: Any] = ["op": op, "path": path]
        if let value { object["value"] = value }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
    static func element(_ type: String, _ props: [String: Any] = [:], _ children: [String] = []) -> [String: Any] {
        ["type": type, "props": props, "children": children]
    }
    static func source(_ type: String = "Text", _ props: [String: Any] = ["text": "hello"]) -> String {
        patch("/root", "main") + "\n" + patch("/elements/main", element(type, props))
    }
    static func graphSource(_ elements: [String: Any], root: String = "main") -> String {
        patch("/root", root) + "\n" + patch("/elements", elements)
    }

    static func upstream() throws {
        // Verbatim wire shape from genui/ui-render's first example.
        let raw = #"{"op":"add","path":"/root","value":"main"}"# + "\n" +
                  #"{"op":"add","path":"/elements/main","value":{"type":"Card","props":{"title":"Hello"},"children":[]}}"#
        let spec = GenerativeUISpec.parse(raw)
        try check(spec?.root == "main", "Upstream root patch")
        try check(spec?.elements["main"]?.text("title") == "Hello", "Upstream Card title")
        let elements: [String: Any] = [
            "main": element("Card", ["title": "Overview", "description": "Your account summary"], ["stack", "table"]),
            "stack": element("Stack", ["direction": "horizontal", "gap": "sm", "align": "center"], ["heading", "text", "badge", "line", "grid"]),
            "heading": element("Heading", ["text": "Dashboard", "level": "h1"]),
            "text": element("Text", ["text": "<script> & **literal** `code`\n第二行", "variant": "code"]),
            "badge": element("Badge", ["text": "Ready", "variant": "outline"]),
            "line": element("Separator"),
            "grid": element("Grid", ["columns": 2, "gap": "lg"], ["link"]),
            "link": element("Link", ["label": "Source", "href": "src/main.swift#L12"]),
            "table": element("Table", ["columns": ["Name", "Role"], "rows": [["Alice", "admin"], ["Bob", "user"]], "caption": "Users"])
        ]
        let parsed = GenerativeUISpec.parse(graphSource(elements))
        try check(parsed?.elements.count == elements.count, "Common layout and leaf catalog")
        try check(parsed?.elements["text"]?.text("text") == "<script> & **literal** `code`\n第二行", "Properties remain literal")
        try check(GenerativeUISpec.parse(source("Card", ["title": NSNull(), "className": "", "maxWidth": "md", "centered": true])) != nil,
                  "Nullable optional catalog props")
        try check(GenerativeUISpec.parse(source("Grid", ["columns": 6])) != nil, "Bounded grids")
        try check(GenerativeUISpec.parse(source("Grid", ["columns": 7])) == nil, "Invalid grid dimensions")
        try check(GenerativeUISpec.parse(source("Grid", ["columns": 1.5])) == nil, "Fractional grids unsupported")
        try check(GenerativeUISpec.parse(source("Table", ["columns": ["A", "B"], "rows": [["lost"]]])) == nil,
                  "Never truncate ragged table content")
    }

    static func pointers() throws {
        let raw = [
            patch("/root", "a/b~c"), patch("/elements/a~1b~0c", element("Text", ["text": ["$state": "/a~1b/~0key/0"]])),
            patch("/state/a~1b", ["~key": ["first", "third"]]),
            patch("/state/a~1b/~0key/1", "second"),
            patch("replace", "/state/a~1b/~0key/0", "replaced"),
            patch("remove", "/state/a~1b/~0key/2", nil),
            patch("/state/a~1b/~0key/-", "last")
        ].joined(separator: "\n")
        try check(GenerativeUISpec.parse(raw)?.elements["a/b~c"]?.text("text") == "replaced", "RFC6901 decoding and state lookup")
        try check(GenerativeUISpec.parse(raw + "\n" + patch("replace", "/elements/a~1b~0c/props/text/$state", "/a~1b/~0key/1"))?
            .elements["a/b~c"]?.text("text") == "second", "RFC6902 array insertion shifts following items")
        try check(GenerativeUISpec.parse(raw + "\n" + patch("replace", "/elements/a~1b~0c/props/text/$state", "/a~1b/~0key/2"))?
            .elements["a/b~c"]?.text("text") == "last", "Array remove and append")
        let emptyKey = source("Text", ["text": ["$state": "/"]]) + "\n" + patch("/state/", "empty key")
        try check(GenerativeUISpec.parse(emptyKey)?.elements["main"]?.text("text") == "empty key", "Empty pointer token")
        let escaping = graphSource(["main": element("Text", ["text": ["$state": "/~01"]])]) + "\n" + patch("/state/~01", "tilde then one")
        try check(GenerativeUISpec.parse(escaping)?.elements["main"]?.text("text") == "tilde then one", "Decode ~01 once")
        let combiningPath = "/~1\u{301}~0\u{301}"
        let combining = source("Text", ["text": ["$state": combiningPath]]) + "\n" + patch("/state" + combiningPath, "combining marks")
        try check(GenerativeUISpec.parse(combining)?.elements["main"]?.text("text") == "combining marks", "Pointer escapes beside combining Unicode marks")
        let leadingMark = source("Text", ["text": ["$state": "/\u{301}key"]]) + "\n" + patch("/state/\u{301}key", "leading mark")
        try check(GenerativeUISpec.parse(leadingMark)?.elements["main"]?.text("text") == "leading mark", "Delimiter must not consume a combining mark")
        let normalized = source("Text", ["text": ["$state": "/e\u{301}"]]) + "\n" + patch("/state", ["é": "composed"])
        try check(GenerativeUISpec.parse(normalized) == nil, "Never read a different JSON key through Swift canonical equality")
        let whole = patch("", ["root": "main", "elements": ["main": element("Text", ["text": "whole spec"])]])
        try check(GenerativeUISpec.parse(whole)?.elements["main"]?.text("text") == "whole spec", "Empty pointer replaces document")
        for path in ["/state/~2", "/state/~", "/state/__proto__/x", "/state/constructor/x", "/state/prototype/x", "state/x"] {
            try check(GenerativeUISpec.parse(raw + "\n" + patch(path, "x")) == nil, "Reject unsafe or malformed pointer: \(path)")
        }
        for (op, path) in [("replace", "/state/missing"), ("remove", "/state/missing"), ("add", "/state/absent/nested"),
                           ("replace", "/state/a~1b/~0key/-"), ("add", "/state/a~1b/~0key/01"),
                           ("add", "/state/a~1b/~0key/-1"), ("add", "/state/a~1b/~0key/8")] {
            try check(GenerativeUISpec.parse(raw + "\n" + patch(op, path, "x")) == nil, "Strict patch existence/index checks")
        }
        let remove = source("Card", ["title": "gone"]) + "\n" + patch("remove", "/elements/main/props/title", nil)
        try check(GenerativeUISpec.parse(remove)?.elements["main"]?.text("title") == "", "Object remove")
    }

    static func streaming() throws {
        let valid = source()
        try check(GenerativeUISpec.parse("\n\n" + valid + "\n") != nil, "First nonempty patch line")
        for tail in [#"{"op":"add","path":"/state/x","value":"par"#, #"{"op":"add","path":"/state/x","value":[1,"#, #"{"op":"add","path":"/state/x","value":1e"#] {
            try check(GenerativeUISpec.parse(valid + "\n" + tail, streaming: true) != nil, "Skip incomplete final streaming JSON")
            try check(GenerativeUISpec.parse(valid + "\n" + tail) == nil, "Finalized malformed source must fallback")
            try check(GenerativeUISpec.parse(valid + "\n" + tail + "\n" + patch("/state/y", 1), streaming: true) == nil, "Incomplete middle line must fallback")
        }
        for invalid in [#"{"op":"move","path":"/root","from":"/state/root"}"#,
                        #"{"op":"add","path":"/root"}"#, #"{"op":"add","path":false,"value":"main"}"#,
                        #"{"op":"add","op":"remove","path":"/root","value":"main"}"#,
                        #"{"op":"add","path":"/state/x","value":BOGUS"#,
                        #"{"op":"add","path":"/state/x","value":"\q"#,
                        #"{"op":"add","path":"/state/x","value":01"#,
                        #"{"op":"add","path":"/state/x","value":1e999}"#,
                        #"{"op":"add","path":"/state/x","value":true,}"#, "not json"] {
            try check(GenerativeUISpec.parse(valid + "\n" + invalid, streaming: true) == nil, "Malformed or unsupported tail must fallback: \(invalid)")
        }
        for ordinary in ["Name: rpm\nVersion: 1", "# spec file\n" + valid, "", "{\"root\":\"main\",\"elements\":{}}", "[" + patch("/root", "main") + "]"] {
            try check(GenerativeUISpec.parse(ordinary) == nil, "Non-patch first line remains ordinary code")
        }
        try check(GenerativeUISpec.parse(#"{"op":"add","path":"/root","value":"main"}"#) == nil, "No root element yet")
        try check(GenerativeUISpec.parse(valid.replacingOccurrences(of: "\n", with: "\r\n")) != nil, "CRLF input")
        try check(GenerativeUISpec.parse(valid + "\n" + patch("replace", "/elements/main/props/text", "complete"), streaming: true)?
            .elements["main"]?.text("text") == "complete", "Complete last line applies without trailing newline")
    }

    static func unsupported() throws {
        for type in ["Button", "Input", "Tabs", "Unknown", "Metric", "RadarChart", "RadialChart", "ScatterChart"] {
            try check(GenerativeUISpec.parse(source(type)) == nil, "Unsupported component preserves source: \(type)")
        }
        for property: [String: Any] in [["on": ["press": ["action": "setState"]]], ["repeat": ["statePath": "/items"]],
                                       ["visible": false], ["visible": true], ["slots": ["footer": ["child"]]]] {
            var root = element("Card", [:], [])
            root.merge(property) { _, new in new }
            try check(GenerativeUISpec.parse(graphSource(["main": root, "child": element("Text", ["text": "must not disappear"])])) == nil,
                      "Unsupported top-level features preserve whole source")
        }
        for props: [String: Any] in [["text": "ok", "action": "navigate"], ["text": "ok", "unknown": true],
                                    ["text": ["$bindState": "/text"]], ["text": ["$item": "title"]],
                                    ["text": ["$state": "/title", "eq": "x"]], ["text": ["$state": "/missing"]]] {
            try check(GenerativeUISpec.parse(source("Text", props)) == nil, "Unsupported props/expressions preserve source")
        }
        try check(GenerativeUISpec.parse(source("Card", ["className": "hidden text-red-500"])) == nil, "Never silently ignore CSS")
        try check(GenerativeUISpec.parse(source("Stack", ["justify": "between"])) == nil, "Unsupported flex justification")
        try check(GenerativeUISpec.parse(source("Stack", ["align": "stretch"])) == nil, "Unsupported stretching")
        try check(GenerativeUISpec.parse(source("Card") + "\n" + patch("/effects", [])) == nil, "Unknown document keys")
        let dataAsExpression = source("Text", ["text": ["$state": "/title"]]) + "\n" + patch("/state/title", ["$state": "/other"])
        try check(GenerativeUISpec.parse(dataAsExpression) == nil, "State values never become new expressions")
        try check(GenerativeUISpec.parse(graphSource(["main": element("Text", ["text": "leaf"], ["child"]),
                                                    "child": element("Text", ["text": "lost"])])) == nil, "Leaf children must not disappear")
    }

    static func graphs() throws {
        let text = element("Text", ["text": "shared"])
        try check(GenerativeUISpec.parse(graphSource(["main": element("Stack", [:], ["main"])])) == nil, "Self cycle")
        try check(GenerativeUISpec.parse(graphSource(["main": element("Card", [:], ["a"]), "a": element("Stack", [:], ["main"])])) == nil, "Indirect child cycle")
        var slot = element("Card")
        slot["slots"] = ["footer": ["main"]]
        try check(GenerativeUISpec.parse(graphSource(["main": slot])) == nil, "Cycle through slots")
        slot["slots"] = ["footer": ["a"]]
        try check(GenerativeUISpec.parse(graphSource(["main": slot, "a": element("Card", [:], ["main"])])) == nil, "Mixed children/slots cycle")
        try check(GenerativeUISpec.parse(graphSource(["main": element("Card", [:], ["missing"])])) == nil, "Unresolved child")
        try check(GenerativeUISpec.parse(graphSource(["main": element("Card", [:], ["a", "a"]), "a": text])) != nil, "Small shared DAG renders both instances")
        var dag: [String: Any] = ["leaf": text]
        for i in (0..<12).reversed() { dag["n\(i)"] = element("Stack", [:], Array(repeating: i == 11 ? "leaf" : "n\(i + 1)", count: 2)) }
        try check(GenerativeUISpec.parse(graphSource(dag, root: "n0")) == nil, "Exponential DAG expansion is bounded")
        var chain: [String: Any] = ["leaf": text]
        for i in (0..<GenerativeUISpec.Limits.renderDepth).reversed() { chain["n\(i)"] = element("Stack", [:], [i == GenerativeUISpec.Limits.renderDepth - 1 ? "leaf" : "n\(i + 1)"]) }
        try check(GenerativeUISpec.parse(graphSource(chain, root: "n0")) == nil, "Depth bound")
        let bigTable = element("Table", ["columns": ["A", "B"], "rows": Array(repeating: ["x", "y"], count: 1_000)])
        try check(GenerativeUISpec.parse(graphSource(["main": element("Stack", [:], Array(repeating: "table", count: 5)), "table": bigTable])) == nil,
                  "Expanded work counts repeated table cells as well as nodes")
        let longText = element("Text", ["text": String(repeating: "x", count: 16_000)])
        try check(GenerativeUISpec.parse(graphSource(["main": element("Stack", [:], Array(repeating: "text", count: 34)), "text": longText])) == nil,
                  "A shared long text node cannot amplify displayed bytes beyond the budget")
    }

    static func bounds() throws {
        try check(GenerativeUISpec.parse(String(repeating: " ", count: GenerativeUISpec.Limits.inputBytes + 1)) == nil, "Input byte cap")
        let valid = source()
        try check(GenerativeUISpec.parse(valid + String(repeating: " ", count: GenerativeUISpec.Limits.inputBytes - valid.utf8.count)) != nil,
                  "Exact input byte boundary remains valid")
        try check(GenerativeUISpec.parse(source("Text", ["text": String(repeating: "a", count: 16_385)])) == nil, "Per-string cap")
        let deep = source() + "\n" + #"{"op":"add","path":"/state/x","value":"# + String(repeating: "[", count: 1_000)
        try check(GenerativeUISpec.parse(deep, streaming: true) == nil, "Bound recursion before Foundation decoding even for incomplete input")
        let patches = source() + "\n" + Array(repeating: patch("/state/x", true), count: GenerativeUISpec.Limits.patches).joined(separator: "\n")
        try check(GenerativeUISpec.parse(patches) == nil, "Patch cap")
        var many: [String: Any] = [:]
        for i in 0...GenerativeUISpec.Limits.elements { many["n\(i)"] = element("Text", ["text": "x"]) }
        try check(GenerativeUISpec.parse(graphSource(many, root: "n0")) == nil, "Element cap")
        let wide = source() + "\n" + patch("/state/wide", Array(repeating: 0, count: GenerativeUISpec.Limits.jsonNodes))
        try check(GenerativeUISpec.parse(wide) == nil, "JSON value count cap")
        let traversals = source() + "\n" + patch("/state/large", Array(repeating: 0, count: 2_000)) + "\n" +
            Array(repeating: patch("/state/x", 1), count: 150).joined(separator: "\n")
        try check(GenerativeUISpec.parse(traversals) == nil, "Cumulative patch traversal budget")
        let table = source("Table", ["columns": ["A", "B"], "rows": Array(repeating: ["a", "b"], count: 1_024)])
        try check(GenerativeUISpec.parse(table) == nil, "Table cell budget includes headers")
        let unicode = source("Text", ["text": "你好 \"quoted\" \\ newline\n🧪"])
        try check(GenerativeUISpec.parse(unicode)?.elements["main"]?.text("text") == "你好 \"quoted\" \\ newline\n🧪", "JSON escaped and Unicode properties")
    }

    static func charts() throws {
        // Actual charts.ts examples (not a generic labels/values chart API).
        let data: [[String: Any]] = [["month": "Jan", "desktop": 186, "mobile": 80], ["month": "Feb", "desktop": 305, "mobile": 200], ["month": "Mar", "desktop": 237, "mobile": 120]]
        let series: [[String: Any]] = [["key": "desktop", "label": "Desktop"], ["key": "mobile", "label": "Mobile"]]
        let props: [String: Any] = ["data": data, "xKey": "month", "series": series]
        let bar = GenerativeUISpec.parse(source("BarChart", props))?.elements["main"]?.chart
        try check(bar?.points.count == 6 && bar?.points.first?.value == 186, "Upstream series data")
        try check(bar?.series.map(\.label) == ["Desktop", "Mobile"], "Series labels")
        for type in ["LineChart", "AreaChart"] {
            for curve in ["linear", "step"] {
                var p = props
                p["curve"] = curve
                try check(GenerativeUISpec.parse(source(type, p))?.elements["main"]?.chart?.curve == curve, "Supported native curve")
            }
            try check(GenerativeUISpec.parse(source(type, props)) == nil, "Default natural spline must preserve source")
        }
        var horizontal = props
        horizontal.merge(["stacked": true, "horizontal": true, "labels": true, "legend": true, "height": 300]) { _, x in x }
        let options = GenerativeUISpec.parse(source("BarChart", horizontal))?.elements["main"]?.chart
        try check(options?.horizontal == true && options?.stacked == true && options?.labels == true && options?.height == 300, "Bar options")
        let pieProps: [String: Any] = ["data": [["browser": "Chrome", "visitors": 275], ["browser": "Safari", "visitors": 200], ["browser": "Firefox", "visitors": 187]],
                                       "nameKey": "browser", "valueKey": "visitors", "centerLabel": "Visitors"]
        let pie = GenerativeUISpec.parse(source("PieChart", pieProps))?.elements["main"]?.chart
        try check(pie?.total == 662 && pie?.donut == true && pie?.centerLabel == "Visitors", "Upstream pie center caption implies donut")
        let bound = source("BarChart", ["data": ["$state": "/sales"], "xKey": "month", "series": series]) + "\n" + patch("/state/sales", data)
        try check(GenerativeUISpec.parse(bound)?.elements["main"]?.chart?.points.count == 6, "Read-only state-bound chart data")
        var decimal = props
        decimal["data"] = [["month": "Jan", "desktop": " 1.25e2 ", "mobile": "-4"]]
        try check(GenerativeUISpec.parse(source("BarChart", decimal))?.elements["main"]?.chart?.points.first?.value == 125, "Numeric string cells")
        var escaped = props
        escaped["series"] = [["key": "a/b~c \"", "label": "<tag>"]]
        escaped["data"] = [["month": "Jan", "a/b~c \"": 3]]
        try check(GenerativeUISpec.parse(source("BarChart", escaped))?.elements["main"]?.chart?.points.first?.value == 3, "Chart field names are data, never code")
        for modification: [String: Any] in [["height": 601], ["height": 0], ["series": []], ["series": Array(repeating: ["key": "desktop"], count: 9)],
                                           ["data": Array(repeating: data[0], count: 129)], ["data": [data[0], data[0]]],
                                           ["data": [["month": "Jan", "desktop": NSNull(), "mobile": 80]]], ["labels": "yes"],
                                           ["data": [["month": "Jan", "desktop": "NaN", "mobile": true]]], ["unknown": true]] {
            var p = props
            p.merge(modification) { _, x in x }
            try check(GenerativeUISpec.parse(source("BarChart", p)) == nil, "Unsupported/oversized chart must preserve source")
        }
        var tooMany = props
        tooMany["data"] = (0..<128).map { ["month": "m\($0)", "a": 1, "b": 2, "c": 3, "d": 4, "e": 5] as [String: Any] }
        tooMany["series"] = ["a", "b", "c", "d", "e"]
        try check(GenerativeUISpec.parse(source("BarChart", tooMany)) == nil, "Point product bound")
        for value in [-1, 0] {
            try check(GenerativeUISpec.parse(source("PieChart", ["data": [["name": "A", "value": value]], "nameKey": "name", "valueKey": "value"])) == nil,
                      "Negative/zero-total pie preserves source")
        }
        try check(GenerativeUISpec.parse(source("BarChart", ["labels": ["A"], "values": [1]])) == nil, "Never invent a chart data schema")
    }

    static func links() throws {
        for raw in ["https://example.test/path?q=1", "http://localhost:8080", "mailto:dev@example.test", "file:///repo/docs/report.pdf", "codeg://session/123", "src/main.swift#L12", "/repo/file.txt", "../docs/readme.md"] {
            try check(GenerativeUISpec.linkURL(raw)?.absoluteString == URL(string: raw)?.absoluteString, "Keep session/file/web routing URL unchanged: \(raw)")
            try check(GenerativeUISpec.parse(source("Link", ["label": "Open", "href": raw])) != nil, "Accept validated link")
        }
        for raw in ["javascript:alert(1)", "data:text/html,hi", "vbscript:x", "intent:foo", "tel:123", "//evil.test/file", "https://", "https://u:p@example.test",
                    "codeg://session/not-a-number", "codeg://other/123", "file://remote/repo/file", " https://example.test", "https://example.test\n", "a\\b.md", "#anchor", "javascript%3Aalert(1)"] {
            try check(GenerativeUISpec.linkURL(raw) == nil, "Unsafe/unsupported URL must preserve source: \(raw)")
            try check(GenerativeUISpec.parse(source("Link", ["label": "Open", "href": raw])) == nil, "Invalid link rejects the full spec")
        }
    }
}
