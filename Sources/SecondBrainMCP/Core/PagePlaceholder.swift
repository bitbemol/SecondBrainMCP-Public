import Foundation

/// Centralized placeholder messages for PDF pages that couldn't produce real text.
/// All placeholders share the `[SecondBrainMCP:` prefix so SearchEngine can skip them.
enum PagePlaceholder {

    case blank(page: Int)
    case inaccessible(page: Int)
    case extractionFailed(page: Int)

    /// The marker prefix used by all placeholders. SearchEngine checks this to skip non-content pages.
    static let prefix = "[SecondBrainMCP:"

    var message: String {
        switch self {
        case .blank(let page):
            return "\(Self.prefix) page \(page) — blank or image-only, no extractable text.]"
        case .inaccessible(let page):
            return "\(Self.prefix) page \(page) — inaccessible (corrupt or missing in PDF).]"
        case .extractionFailed(let page):
            return "\(Self.prefix) page \(page) extraction failed — subprocess timed out or crashed. Manual review recommended.]"
        }
    }

    /// Returns true if the given string is a placeholder (not real page content).
    static func isPlaceholder(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }
}
