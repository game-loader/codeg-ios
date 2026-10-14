import Foundation

// From the repository root, using the production Foundation parser:
// swiftc -D GENERATIVE_UI_PORTABLE CodegiOS/Models/GenerativeUISpec.swift \
//   CodegiOSTests/GenerativeUISpecTests.swift scripts/test-generative-ui.swift \
//   -o /tmp/codeg-generative-ui-checks && /tmp/codeg-generative-ui-checks
@main
struct GenerativeUIParserChecks {
    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("upstream examples and native catalog", GenerativeUISpecCases.upstream),
            ("patch operations and escaped JSON pointers", GenerativeUISpecCases.pointers),
            ("streaming prefixes and malformed source", GenerativeUISpecCases.streaming),
            ("unsupported content falls back intact", GenerativeUISpecCases.unsupported),
            ("child/slot cycles and expanded DAG bounds", GenerativeUISpecCases.graphs),
            ("input, depth, node, traversal and cell limits", GenerativeUISpecCases.bounds),
            ("upstream chart data and plot limits", GenerativeUISpecCases.charts),
            ("validated links retain environment routing", GenerativeUISpecCases.links)
        ]
        for (name, run) in cases {
            try run()
            print("PASS: \(name)")
        }
        print("PASS: all \(cases.count) GenerativeUISpec regression groups")
    }
}
