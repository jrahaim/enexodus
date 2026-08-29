import Foundation
import XCTest

@testable import enexodus

final class MarkdownRendererTests: XCTestCase {

    // MARK: Helpers

    private func render(
        _ body: String,
        resources: ResourceIndex = .empty
    ) -> RenderResult {
        MarkdownRenderer(resources: resources).renderENML("<en-note>\(body)</en-note>")
    }

    private func markdown(_ body: String, resources: ResourceIndex = .empty) -> String {
        render(body, resources: resources).markdown
    }

    // MARK: Blocks

    func testParagraphsAndEmptyDivCollapse() {
        XCTAssertEqual(
            markdown("<div>One</div><div><br/></div><div><br/></div><div>Two</div>"),
            "One\n\nTwo"
        )
    }

    func testHeadings() {
        XCTAssertEqual(markdown("<h1>Title</h1>"), "# Title")
        XCTAssertEqual(markdown("<h3>Sub</h3>"), "### Sub")
        XCTAssertEqual(markdown("<h6>Deep</h6>"), "###### Deep")
        XCTAssertEqual(markdown("<h2></h2>"), "", "an empty heading produces no block")
    }

    func testHorizontalRuleAndBlockquote() {
        XCTAssertEqual(markdown("<hr/>"), "---")
        XCTAssertEqual(
            markdown("<blockquote><div>Quoted</div><div>Lines</div></blockquote>"),
            "> Quoted\n>\n> Lines"
        )
    }

    func testHardLineBreakUsesBackslash() {
        XCTAssertEqual(markdown("<div>One<br/>Two</div>"), "One\\\nTwo")
    }

    // MARK: Inline

    func testEmphasisMappings() {
        XCTAssertEqual(markdown("<div><b>bold</b></div>"), "**bold**")
        XCTAssertEqual(markdown("<div><strong>bold</strong></div>"), "**bold**")
        XCTAssertEqual(markdown("<div><i>it</i></div>"), "*it*")
        XCTAssertEqual(markdown("<div><em>it</em></div>"), "*it*")
        XCTAssertEqual(markdown("<div><s>gone</s></div>"), "~~gone~~")
        XCTAssertEqual(markdown("<div><strike>gone</strike></div>"), "~~gone~~")
        XCTAssertEqual(markdown("<div><del>gone</del></div>"), "~~gone~~")
        XCTAssertEqual(markdown("<div><u>under</u></div>"), "<u>under</u>")
    }

    func testEmphasisPushesWhitespaceOutsideDelimiters() {
        // `** bold **` is not emphasis in CommonMark.
        XCTAssertEqual(markdown("<div>a<b> bold </b>b</div>"), "a **bold** b")
    }

    func testEmphasisWithNoTextEmitsNoDelimiters() {
        XCTAssertEqual(markdown("<div>a<b>  </b>b</div>"), "a  b")
    }

    func testStyledSpansMapToEmphasis() {
        XCTAssertEqual(
            markdown("<div><span style=\"font-weight: bold;\">x</span></div>"),
            "**x**"
        )
        XCTAssertEqual(
            markdown("<div><span style=\"font-style: italic;\">x</span></div>"),
            "*x*"
        )
        XCTAssertEqual(
            markdown("<div><span style=\"text-decoration: line-through;\">x</span></div>"),
            "~~x~~"
        )
        XCTAssertEqual(
            markdown("<div><span style=\"color: #ff0000;\">x</span></div>"),
            "x",
            "a span with no semantic style is transparent, not a fallback"
        )
    }

    func testLinks() {
        XCTAssertEqual(
            markdown("<div><a href=\"https://example.com\">text</a></div>"),
            "[text](https://example.com)"
        )
        XCTAssertEqual(
            markdown("<div><a href=\"https://example.com/a(b)\">t</a></div>"),
            "[t](<https://example.com/a(b)>)",
            "a destination containing parens must be angle-bracketed"
        )
        XCTAssertEqual(
            markdown("<div><a href=\"https://example.com\"></a></div>"),
            "[https://example.com](https://example.com)",
            "an empty label falls back to the destination"
        )
        XCTAssertEqual(markdown("<div><a>bare</a></div>"), "bare")
    }

    func testJavascriptURLIsDroppedButTextSurvives() {
        XCTAssertEqual(markdown("<div><a href=\"javascript:alert(1)\">click</a></div>"), "click")
        XCTAssertEqual(
            markdown("<div><a href=\"JaVaScRiPt&#9;:alert(1)\">click</a></div>"),
            "click",
            "scheme detection must survive case and embedded control characters"
        )
    }

    func testCodeSpanAndFence() {
        XCTAssertEqual(markdown("<div><code>let x = 1</code></div>"), "`let x = 1`")
        XCTAssertEqual(markdown("<pre>line one\nline two</pre>"), "```\nline one\nline two\n```")
        XCTAssertEqual(
            markdown("<div style=\"--en-codeblock:true;\"><div>a()</div><div>b()</div></div>"),
            "```\na()\nb()\n```"
        )
    }

    func testCodeFenceGrowsToAvoidCollision() {
        XCTAssertEqual(markdown("<pre>a ``` b</pre>"), "````\na ``` b\n````")
    }

    // MARK: Lists

    func testNestedListIndentation() {
        XCTAssertEqual(
            markdown("<ul><li>A</li><li>B<ul><li>B1</li></ul></li></ul>"),
            "- A\n- B\n    - B1"
        )
    }

    func testOrderedListNumbering() {
        XCTAssertEqual(markdown("<ol><li>a</li><li>b</li><li>c</li></ol>"), "1. a\n2. b\n3. c")
    }

    func testTodoInListItemBecomesCheckbox() {
        XCTAssertEqual(
            markdown("<ul><li><en-todo checked=\"true\"/>done</li><li><en-todo checked=\"false\"/>open</li></ul>"),
            "- [x] done\n- [ ] open"
        )
    }

    /// Per plan §4 WP-3.2 an `<en-todo>` outside a list item renders as an inline glyph.
    /// This is the shape Evernote uses for its most common checklists — see the report.
    func testTodoOutsideListItemRendersAsGlyph() {
        XCTAssertEqual(markdown("<div><en-todo checked=\"false\"/>task</div>"), "\u{2610}task")
        XCTAssertEqual(markdown("<div>a <en-todo checked=\"true\"/> b</div>"), "a \u{2611} b")
    }

    func testEmptyListItemKeepsItsBullet() {
        XCTAssertEqual(markdown("<ul><li>a</li><li></li><li>c</li></ul>"), "- a\n-\n- c")
    }

    // MARK: Tables

    func testSimpleTableBecomesGFM() {
        XCTAssertEqual(
            markdown("<table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>"),
            "| A | B |\n| --- | --- |\n| 1 | 2 |"
        )
    }

    func testTablePipesAreEscapedAndRowsPadded() {
        XCTAssertEqual(
            markdown("<table><tr><td>a|b</td><td>c</td></tr><tr><td>only</td></tr></table>"),
            "| a\\|b | c |\n| --- | --- |\n| only |  |"
        )
    }

    func testTableWithTheadIsFlattened() {
        XCTAssertEqual(
            markdown("<table><thead><tr><th>H</th></tr></thead><tbody><tr><td>v</td></tr></tbody></table>"),
            "| H |\n| --- |\n| v |"
        )
    }

    func testMergedCellsFallBackToHTML() {
        let result = render("<table><tr><td colspan=\"2\">x</td></tr></table>")
        XCTAssertEqual(result.fallbackBlocks, 1)
        XCTAssertTrue(result.markdown.contains("reason=\"merged-cells\""))
        XCTAssertTrue(result.markdown.contains("colspan=\"2\""))
    }

    func testNestedTableFallsBackToHTML() {
        let result = render("<table><tr><td><table><tr><td>i</td></tr></table></td></tr></table>")
        XCTAssertEqual(result.fallbackBlocks, 1)
        XCTAssertTrue(result.markdown.contains("reason=\"nested-table\""))
    }

    func testListInsideCellFallsBackToHTML() {
        let result = render("<table><tr><td><ul><li>a</li></ul></td></tr></table>")
        XCTAssertEqual(result.fallbackBlocks, 1)
        XCTAssertTrue(result.markdown.contains("reason=\"block-content-in-cell\""))
    }

    // MARK: Media

    private var mediaIndex: ResourceIndex {
        ResourceIndex(byHash: [
            "aaaa": ResolvedResource(
                relativePath: "_attachments/pic.png", displayName: "pic.png", isImage: true
            ),
            "bbbb": ResolvedResource(
                relativePath: "_attachments/spec file.pdf", displayName: "spec file.pdf",
                isImage: false
            ),
        ])
    }

    func testImageAndAttachmentReferences() {
        XCTAssertEqual(
            markdown("<div><en-media hash=\"AAAA\" type=\"image/png\"/></div>", resources: mediaIndex),
            "![pic.png](_attachments/pic.png)",
            "hash matching must be case-insensitive"
        )
        XCTAssertEqual(
            markdown("<div><en-media hash=\"bbbb\" type=\"application/pdf\"/></div>", resources: mediaIndex),
            "[spec file.pdf](<_attachments/spec file.pdf>)",
            "a path with a space must be angle-bracketed"
        )
    }

    func testOrphanMediaIsMarkedAndCountedNeverSilent() {
        let result = render(
            "<div>before</div><div><en-media hash=\"dead\" type=\"image/png\"/></div><div>after</div>",
            resources: mediaIndex
        )
        XCTAssertEqual(result.mediaReferences, 1)
        XCTAssertEqual(result.orphanMediaReferences, 1)
        XCTAssertTrue(result.markdown.contains(orphanMediaMarkerPrefix))
        XCTAssertTrue(result.warnings.contains { $0.kind == .orphanMedia })
        XCTAssertTrue(result.markdown.contains("before"))
        XCTAssertTrue(result.markdown.contains("after"), "content after an orphan must survive")
    }

    // MARK: Escaping

    func testInlineMetacharactersAreEscaped() {
        XCTAssertEqual(markdown("<div>*stars* and [brackets]</div>"), "\\*stars\\* and \\[brackets\\]")
        XCTAssertEqual(markdown("<div>a `tick` b</div>"), "a \\`tick\\` b")
        XCTAssertEqual(markdown("<div>a &lt;tag&gt; b</div>"), "a \\<tag> b")
    }

    func testUnderscoreOnlyEscapedAtWordBoundaries() {
        XCTAssertEqual(markdown("<div>snake_case_name</div>"), "snake_case_name")
        XCTAssertEqual(markdown("<div>_leading</div>"), "\\_leading")
    }

    func testLineLeadingSyntaxIsEscaped() {
        XCTAssertEqual(markdown("<div># not a heading</div>"), "\\# not a heading")
        XCTAssertEqual(markdown("<div>- not a list</div>"), "\\- not a list")
        XCTAssertEqual(markdown("<div>1. not ordered</div>"), "1\\. not ordered")
        XCTAssertEqual(markdown("<div>&gt; not a quote</div>"), "\\> not a quote")
        XCTAssertEqual(markdown("<div>2024 was a year</div>"), "2024 was a year")
    }

    // MARK: Fallback

    func testUnknownElementFallsBackAndKeepsText() {
        let result = render("<div>before</div><svg><text>inside svg</text></svg><div>after</div>")
        XCTAssertEqual(result.fallbackBlocks, 1)
        XCTAssertTrue(result.markdown.contains("reason=\"unmapped-element:svg\""))
        XCTAssertTrue(result.markdown.contains("inside svg"))
        XCTAssertTrue(result.markdown.contains("after"))
    }

    func testEnCryptFallsBackWithCiphertextIntact() {
        let result = render("<div><en-crypt cipher=\"RC2\" length=\"64\">SECRET==</en-crypt></div>")
        XCTAssertEqual(result.fallbackBlocks, 1)
        XCTAssertTrue(result.markdown.contains("SECRET=="))
        XCTAssertTrue(result.markdown.contains("cipher=\"RC2\""))
    }

    func testFallbackStripsScriptsAndEventHandlers() {
        let result = render(
            "<figure onclick=\"steal()\"><script>evil()</script><span>kept</span></figure>"
        )
        XCTAssertTrue(result.markdown.contains("kept"))
        XCTAssertFalse(result.markdown.contains("onclick"))
        XCTAssertFalse(result.markdown.contains("evil()"))
        XCTAssertFalse(result.markdown.lowercased().contains("<script"))
    }

    func testFallbackResolvesMediaSoAttachmentsStayLinked() {
        let result = render(
            "<table><tr><td colspan=\"2\"><en-media hash=\"aaaa\" type=\"image/png\"/></td></tr></table>",
            resources: mediaIndex
        )
        XCTAssertTrue(result.markdown.contains("_attachments/pic.png"))
    }

    func testFallbackBlockContainsNoBlankLine() {
        // A blank line would terminate the raw-HTML block and hand the rest back to Markdown.
        let result = render("<svg>\n\n\n<text>a</text>\n\n\n</svg>")
        let block = result.markdown.components(separatedBy: "\n")
        XCTAssertFalse(block.contains(""), "fallback HTML must not contain a blank line")
    }

    func testUnparseableENMLStillKeepsContent() {
        let result = MarkdownRenderer().renderENML("<en-note><div>unclosed text")
        XCTAssertTrue(result.warnings.contains { $0.kind == .enmlParseFailure })
        XCTAssertTrue(result.markdown.contains("unclosed text"))
    }

    func testUnclosedVoidElementsAreRepairedNotFallenBackOn() {
        let result = MarkdownRenderer().renderENML("<en-note><div>a<br>b</div></en-note>")
        XCTAssertEqual(result.fallbackBlocks, 0)
        XCTAssertEqual(result.markdown, "a\\\nb")
    }

    // MARK: Entities

    func testNamedEntitiesAreDecoded() {
        XCTAssertEqual(
            markdown("<div>Caf&eacute; &mdash; 50&nbsp;&euro;</div>"),
            "Café — 50\u{00A0}€"
        )
    }

    func testUnknownEntityIsKeptAsLiteralText() {
        XCTAssertEqual(markdown("<div>a &bogus; b</div>"), "a &bogus; b")
    }

    func testBareAmpersandIsHandled() {
        XCTAssertEqual(markdown("<div>Tom & Jerry</div>"), "Tom & Jerry")
    }

    // MARK: Losslessness — the non-negotiable (plan §6.1)

    /// Negative control. The losslessness check is the plan's one non-negotiable, so it has to
    /// be demonstrably capable of failing — otherwise the tests above prove nothing.
    func testLosslessnessCheckActuallyDetectsLostText() throws {
        let tree = try ENMLDocument.parse(
            "<en-note><div>alpha</div><div>beta</div><div>gamma</div></en-note>"
        )
        let source = Losslessness.sourceText(tree)

        let intact = Losslessness.outputText("alpha\n\nbeta\n\ngamma")
        XCTAssertNil(Losslessness.firstMissing(source, in: intact))

        let dropped = Losslessness.outputText("alpha\n\ngamma")
        XCTAssertNotNil(
            Losslessness.firstMissing(source, in: dropped),
            "a dropped paragraph must be detected"
        )

        let reordered = Losslessness.outputText("gamma\n\nbeta\n\nalpha")
        XCTAssertNotNil(
            Losslessness.firstMissing(source, in: reordered),
            "reordered text must be detected"
        )

        let truncated = Losslessness.outputText("alpha\n\nbeta\n\ngam")
        XCTAssertNotNil(
            Losslessness.firstMissing(source, in: truncated),
            "a truncated word must be detected"
        )
    }

    func testEveryFixtureNotePreservesAllSourceText() throws {
        for fixture in Fixtures.names {
            for note in try Fixtures.notes(in: fixture) {
                guard let tree = try? ENMLDocument.parse(note.content) else { continue }

                let index = ResourceIndex(
                    byHash: note.resourcesByHash().mapValues { resource in
                        ResolvedResource(
                            relativePath: "_attachments/\(resource.md5).bin",
                            displayName: resource.fileName ?? resource.md5,
                            isImage: resource.isImage
                        )
                    }
                )
                let rendered = MarkdownRenderer(resources: index).render(tree).markdown

                let missing = Losslessness.firstMissing(
                    Losslessness.sourceText(tree),
                    in: Losslessness.outputText(rendered)
                )
                XCTAssertNil(
                    missing,
                    "\(fixture).enex / \"\(note.title)\": source text not preserved: \(missing ?? "")"
                )
            }
        }
    }

    func testFallbackSubtreesPreserveAllSourceText() throws {
        let cases = [
            "<table><tr><td colspan=\"2\">alpha beta</td></tr><tr><td>gamma</td><td>delta</td></tr></table>",
            "<table><tr><td>outer</td><td><table><tr><td>inner</td></tr></table></td></tr></table>",
            "<en-crypt cipher=\"RC2\">Q0lQSEVSVEVYVA==</en-crypt>",
            "<svg><text>vector words here</text></svg>",
            "<dl><dt>term</dt><dd>definition</dd></dl>",
            "<figure onclick=\"x()\"><figcaption>caption &amp; text &lt; here</figcaption></figure>",
        ]
        for body in cases {
            let tree = try ENMLDocument.parse("<en-note>\(body)</en-note>")
            let rendered = MarkdownRenderer().render(tree).markdown
            let missing = Losslessness.firstMissing(
                Losslessness.sourceText(tree),
                in: Losslessness.outputText(rendered)
            )
            XCTAssertNil(missing, "\(body): source text not preserved: \(missing ?? "")")
        }
    }
}
