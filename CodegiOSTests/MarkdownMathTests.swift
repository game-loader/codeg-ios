import Foundation
import UIKit
import XCTest
import SwiftMath
@testable import Codeg

@MainActor
final class MarkdownMathTests: XCTestCase {
    func testInlineFractionIsMaskedAndRetainsSource() throws {
        let result = MarkdownMath.maskInline(#"Area \(\frac{a}{b}\) remains styled."#)
        let formula = try XCTUnwrap(result.formulas.values.first)

        XCTAssertEqual(result.formulas.count, 1)
        XCTAssertFalse(result.text.contains(#"\("#))
        XCTAssertEqual(formula.latex, #"\frac{a}{b}"#)
        XCTAssertEqual(formula.source, #"\(\frac{a}{b}\)"#)
        XCTAssertFalse(formula.display)
    }

    func testCodeSpansLinksCurrencyEscapesAndUnclosedInputStayLiteral() {
        let raw = #"`\(code\)` and ``\[code\]`` [link](https://example.test/\(path\)) \(x\) \(unclosed $HOME $9.99"#
        let result = MarkdownMath.maskInline(raw)

        XCTAssertEqual(result.formulas.count, 1)
        XCTAssertTrue(result.text.contains(#"`\(code\)`"#))
        XCTAssertTrue(result.text.contains(#"``\[code\]``"#))
        XCTAssertTrue(result.text.contains(#"[link](https://example.test/\(path\))"#))
        XCTAssertTrue(result.text.contains(#"\(unclosed $HOME $9.99"#))

        let escaped = MarkdownMath.maskInline(#"\\(literal) and $HOME $9.99"#)
        XCTAssertEqual(escaped.text, #"\\(literal) and $HOME $9.99"#)
        XCTAssertTrue(escaped.formulas.isEmpty)
    }

    func testMultilineDisplayMatrixIsParsedBeforeTableClassification() {
        let latex = #"\begin{matrix}"# + "\n" + #"a & b \\"# + "\n" + #"c & d"# + "\n" + #"\end{matrix}"#
        let raw = "$$\n" + latex + "\n$$"
        let nodes = MarkdownParser.parse(raw, inline: { $0 })
        XCTAssertEqual(nodes, [.math(latex: latex, source: raw)])
    }

    func testQuotedDisplayFormulaRecursesAndMathFenceIsNotCode() {
        let latex = #"\begin{cases}"# + "\n" + #"x & x > 0 \\"# + "\n" + #"0 & otherwise"# + "\n" + #"\end{cases}"#
        let source = #"\["# + "\n" + latex + "\n" + #"\]"#
        let quoted = source.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        XCTAssertEqual(MarkdownParser.parse(quoted, inline: { $0 }), [.quote([.math(latex: latex, source: source)])])

        let formula = #"\frac{1}{2}"#
        let fenced = MarkdownParser.parse("```math\n" + formula + "\n```", inline: { $0 })
        XCTAssertEqual(fenced, [.math(latex: formula, source: formula)])

        let code = #"let x = "\(literal)""#
        let normalCode = MarkdownParser.parse("```swift\n" + code + "\n```", inline: { $0 })
        XCTAssertEqual(normalCode, [.code(language: "swift", code: code)])
    }

    func testIsolatedSameLineDisplayFormulaAndUnclosedDisplayRemainDistinct() {
        let isolated = MarkdownParser.parse("$$ x + y $$", inline: { $0 })
        XCTAssertEqual(isolated, [.math(latex: " x + y ", source: "$$ x + y $$")])

        let unclosed = MarkdownParser.parse("$$\nx + y", inline: { $0 })
        XCTAssertEqual(unclosed, [.paragraph("$$\nx + y")])
    }

    func testSwiftMathRendersFractionMatrixAlignedAndCases() {
        let formulas = [
            #"\frac{a}{b}"#,
            #"\begin{matrix} a & b \\ c & d \end{matrix}"#,
            #"\begin{aligned} a &= b \\ c &= d \end{aligned}"#,
            #"\begin{cases} x & x > 0 \\ 0 & otherwise \end{cases}"#
        ]

        for latex in formulas {
            XCTAssertNotNil(
                MathFormulaRenderer.image(latex: latex, fontSize: 20, color: .label, display: true),
                latex
            )
        }
    }

    func testRendererUsesTheSameLatexAndSizeAsSwiftMath() throws {
        let latex = #"\frac{a}{b}"#
        let expectedFormatter = MTMathImage(
            latex: latex,
            fontSize: 20,
            textColor: .label,
            labelMode: .text,
            textAlignment: .left
        )
        let (expectedError, expectedImage) = expectedFormatter.asImage()
        let actualImage = MathFormulaRenderer.image(latex: latex, fontSize: 20, color: .label, display: false)

        XCTAssertNil(expectedError)
        XCTAssertNotNil(expectedImage)
        XCTAssertEqual(actualImage?.size, expectedImage?.size)
    }

    func testRendererRejectsInvalidAndOversizedInputBeforeRasterization() {
        XCTAssertNil(MathFormulaRenderer.image(latex: #"\begin{unknown}x\end{unknown}"#, fontSize: 20, color: .label, display: true))
        XCTAssertNil(MathFormulaRenderer.image(latex: String(repeating: "x", count: 20_000), fontSize: 20, color: .label, display: true))
    }

    func testCommandHeavyMatrixIsMeasuredByLayoutRatherThanSourceLength() {
        let cell = #"\frac{\alpha_i}{\sqrt{\beta_j}}"#
        let latex = #"\begin{bmatrix}"# + Array(repeating: cell + " & " + cell, count: 5).joined(separator: #" \\ "#) + #"\end{bmatrix}"#
        XCTAssertGreaterThan(latex.count, 200)
        XCTAssertNotNil(MathFormulaRenderer.image(latex: latex, fontSize: 20, color: .black, display: true))
    }

    func testTwoEquationsOnOneLineStayDistinctInlineSpans() {
        let raw = "$$a$$ and $$b$$"
        XCTAssertEqual(MarkdownParser.parse(raw, inline: { $0 }), [.paragraph(raw)])
        let masked = MarkdownMath.maskInline(raw)
        XCTAssertEqual(Set(masked.formulas.values.map(\.latex)), Set(["a", "b"]))
    }

    func testEscapedBacktickDoesNotHideFollowingFormula() {
        let raw = #"\` followed by \(x\)"#
        XCTAssertEqual(MarkdownMath.maskInline(raw).formulas.count, 1)
    }

    func testCurrencyAndShellVariablesStayLiteral() {
        let raw = "Cost $9.99 or $19.99; $HOME and $PATH; $x$"
        let masked = MarkdownMath.maskInline(raw)
        XCTAssertTrue(masked.formulas.isEmpty)
        XCTAssertEqual(masked.text, raw)
    }
}
