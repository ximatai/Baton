import Foundation
import Testing
@testable import Baton

struct MarkdownMessageViewTests {
    @Test func markdownRendererParsesCoreChatFormatting() {
        let source = """
        # 标题

        **粗体**、*斜体*、`code`，以及 [Baton](https://example.test)。

        - 第一项
        - 第二项

        ```swift
        let baton = \"ready\"
        ```
        """

        let rendered = BatonMarkdownRenderer.render(source)
        #expect(rendered != nil)
        #expect(rendered.map { String($0.characters).contains("标题") } == true)
        #expect(rendered.map { String($0.characters).contains("let baton") } == true)
        #expect(rendered?.runs.contains(where: { $0.link == URL(string: "https://example.test") }) == true)
    }

    @Test func markdownRendererKeepsHTMLLookingInputAsText() {
        let source = "<script>alert('not executable')</script>"
        let rendered = BatonMarkdownRenderer.render(source)
        #expect(rendered.map { String($0.characters) } == source)
    }

    @Test func markdownRendererDoesNotMixHTMLWithMarkdown() {
        let source = "**Baton** <em>不解释</em>"
        let rendered = BatonMarkdownRenderer.render(source)
        #expect(rendered.map { String($0.characters) } == source)
        #expect(rendered?.runs.contains(where: { $0.inlinePresentationIntent != nil }) == false)
    }
}
