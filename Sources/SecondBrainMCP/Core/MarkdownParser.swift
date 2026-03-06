import Foundation

/// Parses YAML frontmatter and extracts metadata from Markdown files.
/// Stateless — all methods are static. No side effects, easy to test.
struct MarkdownParser {

    struct NoteMetadata: Sendable {
        let title: String
        let tags: [String]
        let created: String?       // ISO date from frontmatter
        let customFields: [String: String]
        let bodyContent: String    // Content after frontmatter
    }

    /// Parse a Markdown file's full text into metadata + body.
    static func parse(content: String, filename: String) -> NoteMetadata {
        let (frontmatter, body) = extractFrontmatter(from: content)

        let fmFields = frontmatter.flatMap { parseFrontmatterFields($0) } ?? [:]

        let title = fmFields["title"]
            ?? extractFirstHeading(from: body)
            ?? Self.titleFromFilename(filename)

        let tags = parseTags(fmFields["tags"])
        let created = fmFields["created"]

        // Collect custom fields (everything except title, tags, created)
        var custom: [String: String] = [:]
        for (key, value) in fmFields where !["title", "tags", "created"].contains(key) {
            custom[key] = value
        }

        return NoteMetadata(
            title: title,
            tags: tags,
            created: created,
            customFields: custom,
            bodyContent: body
        )
    }

    /// Generate minimal YAML frontmatter for a new note.
    static func generateFrontmatter(title: String, tags: [String] = [], date: String? = nil) -> String {
        let dateStr = date ?? ISO8601DateFormatter().string(from: Date()).prefix(10).description
        var lines = ["---"]
        lines.append("title: \(title)")
        lines.append("created: \(dateStr)")
        if !tags.isEmpty {
            let tagList = tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            lines.append("tags: [\(tagList.joined(separator: ", "))]")
        }
        lines.append("---")
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Derive a title from a filename: "my-note.md" → "my note"
    static func titleFromFilename(_ filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        return name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Extract all `[[wikilinks]]` and `[markdown](links)` from content.
    static func extractLinks(from content: String) -> [String] {
        var links: [String] = []

        // [[wikilinks]]
        let wikiPattern = /\[\[([^\]]+)\]\]/
        for match in content.matches(of: wikiPattern) {
            links.append(String(match.1))
        }

        // [text](link) — only relative links, not http
        let mdPattern = /\[([^\]]*)\]\(([^)]+)\)/
        for match in content.matches(of: mdPattern) {
            let target = String(match.2)
            if !target.hasPrefix("http://") && !target.hasPrefix("https://") {
                links.append(target)
            }
        }

        return links
    }

    // MARK: - Private

    /// Extract frontmatter block between first --- and second ---.
    /// Returns (frontmatter text, body text). Frontmatter is nil if not present.
    private static func extractFrontmatter(from content: String) -> (String?, String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return (nil, content)
        }

        // Find the closing ---
        let lines = content.components(separatedBy: "\n")
        guard let firstDashIndex = lines.indices.first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (nil, content)
        }

        // Find the second ---
        let searchStart = firstDashIndex + 1
        guard searchStart < lines.count else { return (nil, content) }

        var closingIndex: Int?
        for i in searchStart..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let closing = closingIndex else {
            return (nil, content)
        }

        let frontmatterLines = lines[(firstDashIndex + 1)..<closing]
        let bodyLines = lines[(closing + 1)...]

        return (
            frontmatterLines.joined(separator: "\n"),
            bodyLines.joined(separator: "\n")
        )
    }

    /// Simple YAML key-value parser. Handles basic `key: value` lines.
    /// Not a full YAML parser — covers the frontmatter subset we need.
    private static func parseFrontmatterFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[trimmed.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)

            fields[key] = value
        }
        return fields
    }

    /// Parse tags from frontmatter value. Handles both `[a, b, c]` and `a, b, c` formats.
    private static func parseTags(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }

        // Strip brackets if present
        var cleaned = raw
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }

        return cleaned
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Extract the first `# Heading` from markdown content.
    private static func extractFirstHeading(from content: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
