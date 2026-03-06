import Testing
import Foundation
@testable import SecondBrainMCP

@Suite("MarkdownParser — Frontmatter")
struct MarkdownParserFrontmatterTests {

    @Test("Parses complete frontmatter")
    func completeFrontmatter() {
        let content = """
        ---
        title: My Note
        tags: [swift, mcp, tools]
        created: 2026-03-01
        ---

        # Content here
        Some body text.
        """

        let result = MarkdownParser.parse(content: content, filename: "my-note.md")
        #expect(result.title == "My Note")
        #expect(result.tags == ["swift", "mcp", "tools"])
        #expect(result.created == "2026-03-01")
        #expect(result.bodyContent.contains("Content here"))
    }

    @Test("Tags without brackets")
    func tagsWithoutBrackets() {
        let content = """
        ---
        title: Test
        tags: alpha, beta, gamma
        ---

        Body.
        """

        let result = MarkdownParser.parse(content: content, filename: "test.md")
        #expect(result.tags == ["alpha", "beta", "gamma"])
    }

    @Test("Tags are normalized to lowercase and trimmed")
    func tagNormalization() {
        let content = """
        ---
        tags: [Swift,  MCP , Tools]
        ---

        Body.
        """

        let result = MarkdownParser.parse(content: content, filename: "test.md")
        #expect(result.tags == ["swift", "mcp", "tools"])
    }

    @Test("Missing frontmatter falls back to heading for title")
    func noFrontmatterUsesHeading() {
        let content = """
        # My Great Note

        Some content here.
        """

        let result = MarkdownParser.parse(content: content, filename: "fallback.md")
        #expect(result.title == "My Great Note")
        #expect(result.tags.isEmpty)
        #expect(result.created == nil)
    }

    @Test("No frontmatter and no heading falls back to filename")
    func noFrontmatterNoHeadingUsesFilename() {
        let content = "Just some plain text without any structure."

        let result = MarkdownParser.parse(content: content, filename: "my-project-notes.md")
        #expect(result.title == "my project notes")
    }

    @Test("Malformed frontmatter (no closing dashes) treated as no frontmatter")
    func malformedFrontmatter() {
        let content = """
        ---
        title: Broken
        tags: [oops]

        # Actual Content

        Body here.
        """

        let result = MarkdownParser.parse(content: content, filename: "broken.md")
        // No closing --- so frontmatter is not parsed
        #expect(result.title == "Actual Content")
    }

    @Test("Empty frontmatter block")
    func emptyFrontmatter() {
        let content = """
        ---
        ---

        # After empty frontmatter
        """

        let result = MarkdownParser.parse(content: content, filename: "empty-fm.md")
        #expect(result.title == "After empty frontmatter")
        #expect(result.tags.isEmpty)
    }

    @Test("Custom fields are captured")
    func customFields() {
        let content = """
        ---
        title: Test
        status: draft
        priority: high
        ---

        Body.
        """

        let result = MarkdownParser.parse(content: content, filename: "test.md")
        #expect(result.customFields["status"] == "draft")
        #expect(result.customFields["priority"] == "high")
        // title, tags, created are NOT in custom fields
        #expect(result.customFields["title"] == nil)
    }
}

@Suite("MarkdownParser — Frontmatter Generation")
struct MarkdownParserGenerationTests {

    @Test("Generate frontmatter with tags")
    func generateWithTags() {
        let fm = MarkdownParser.generateFrontmatter(
            title: "New Note",
            tags: ["swift", "project"],
            date: "2026-03-01"
        )

        #expect(fm.hasPrefix("---\n"))
        #expect(fm.contains("title: New Note"))
        #expect(fm.contains("created: 2026-03-01"))
        #expect(fm.contains("tags: [swift, project]"))
        #expect(fm.hasSuffix("---\n\n"))
    }

    @Test("Generate frontmatter without tags omits tag line")
    func generateWithoutTags() {
        let fm = MarkdownParser.generateFrontmatter(title: "Simple", date: "2026-03-01")

        #expect(fm.contains("title: Simple"))
        #expect(!fm.contains("tags:"))
    }
}

@Suite("MarkdownParser — Links")
struct MarkdownParserLinksTests {

    @Test("Extract wikilinks")
    func wikilinks() {
        let content = "See [[other-note]] and [[projects/my-project]] for details."
        let links = MarkdownParser.extractLinks(from: content)
        #expect(links.contains("other-note"))
        #expect(links.contains("projects/my-project"))
    }

    @Test("Extract relative markdown links, ignore http")
    func markdownLinks() {
        let content = """
        Check [this note](notes/related.md) and [Google](https://google.com).
        Also see [another](../other.md).
        """

        let links = MarkdownParser.extractLinks(from: content)
        #expect(links.contains("notes/related.md"))
        #expect(links.contains("../other.md"))
        #expect(!links.contains("https://google.com"))
    }

    @Test("No links returns empty array")
    func noLinks() {
        let content = "Plain text with no links at all."
        let links = MarkdownParser.extractLinks(from: content)
        #expect(links.isEmpty)
    }
}

@Suite("MarkdownParser — Filename Title")
struct MarkdownParserFilenameTitleTests {

    @Test("Hyphens become spaces")
    func hyphens() {
        #expect(MarkdownParser.titleFromFilename("my-cool-note.md") == "my cool note")
    }

    @Test("Underscores become spaces")
    func underscores() {
        #expect(MarkdownParser.titleFromFilename("my_cool_note.md") == "my cool note")
    }

    @Test("Extension is stripped")
    func extensionStripped() {
        #expect(MarkdownParser.titleFromFilename("README.md") == "README")
    }
}
