import SwiftUI

/// Renders assistant text with Foundation's Markdown parser.  This stays out of
/// the protocol/domain layer: messages are always transported as plain text.
/// `Text` is deliberately used instead of a web view.  HTML-looking input is
/// kept verbatim rather than being handed to Foundation's Markdown parser.
struct MarkdownMessageView: View {
    let source: String

    var body: some View {
        Group {
            if let markdown = BatonMarkdownRenderer.render(source) {
                Text(markdown)
            } else {
                Text(source)
            }
        }
        .textSelection(.enabled)
    }
}

enum BatonMarkdownRenderer {
    /// Raw HTML is deliberately unsupported in V1.  Foundation Markdown treats
    /// some tags as markup, so return an unstyled attributed string for the
    /// entire message whenever it contains a tag-like construct.  That makes
    /// `<script>` and mixed Markdown/HTML visible exactly as server text.
    ///
    /// Returns nil only when Foundation cannot parse non-HTML Markdown, allowing
    /// the caller to present the original message without losing visible text.
    static func render(_ source: String) -> AttributedString? {
        if containsHTMLTag(source) {
            return AttributedString(source)
        }
        do {
            return try AttributedString(
                markdown: source,
                options: .init(
                    interpretedSyntax: .full
                )
            )
        } catch {
            return nil
        }
    }

    private static func containsHTMLTag(_ source: String) -> Bool {
        let pattern = #"<\s*(?:/?[A-Za-z][^>]*|!DOCTYPE\b[^>]*|!--[\s\S]*?--)>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return true
        }
        let range = NSRange(source.startIndex..., in: source)
        return expression.firstMatch(in: source, range: range) != nil
    }
}
