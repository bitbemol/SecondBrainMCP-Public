import Testing
import Foundation
@testable import SecondBrainMCP

// MARK: - Happy Path

@Suite("PathValidator — Happy Path")
struct PathValidatorHappyPathTests {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/notes/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)
        // Create test files
        fm.createFile(atPath: root + "/notes/hello.md", contents: nil)
        fm.createFile(atPath: root + "/notes/projects/app.md", contents: nil)
        fm.createFile(atPath: root + "/references/book.pdf", contents: nil)
    }

    @Test("Simple relative path resolves correctly")
    func simpleRelativePath() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/hello.md", root: root)
        #expect(resolved.hasSuffix("/notes/hello.md"))
        #expect(resolved.hasPrefix(root))
    }

    @Test("Nested relative path resolves correctly")
    func nestedRelativePath() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/projects/app.md", root: root)
        #expect(resolved.hasSuffix("/notes/projects/app.md"))
    }

    @Test("Path with allowed extension passes")
    func allowedExtension() throws {
        let resolved = try PathValidator.resolve(
            relativePath: "notes/hello.md",
            root: root,
            allowedExtensions: ["md", "markdown"]
        )
        #expect(resolved.hasSuffix("/notes/hello.md"))
    }

    @Test("PDF extension passes when allowed")
    func pdfExtension() throws {
        let resolved = try PathValidator.resolve(
            relativePath: "references/book.pdf",
            root: root,
            allowedExtensions: ["pdf"]
        )
        #expect(resolved.hasSuffix("/references/book.pdf"))
    }

    @Test("No extension filter means all extensions pass")
    func noExtensionFilter() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/hello.md", root: root)
        #expect(resolved.hasSuffix("/notes/hello.md"))
    }
}

// MARK: - Traversal Attacks

@Suite("PathValidator — Traversal Attacks")
struct PathValidatorTraversalTests {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    }

    @Test("Basic parent traversal is rejected")
    func basicTraversal() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "../etc/passwd", root: root)
        }
    }

    @Test("Deep traversal is rejected")
    func deepTraversal() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "../../../../../../etc/passwd", root: root)
        }
    }

    @Test("Traversal hidden in subdirectory is rejected")
    func hiddenTraversal() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "notes/../../etc/passwd", root: root)
        }
    }

    @Test("Traversal at end of path is rejected")
    func trailingTraversal() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "notes/..", root: root)
        }
    }

    @Test("URL-encoded traversal is rejected (%2e%2e%2f)")
    func urlEncodedTraversal() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "%2e%2e%2fetc/passwd", root: root)
        }
    }

    @Test("Double URL-encoded traversal is rejected (%252e%252e)")
    func doubleEncodedTraversal() {
        // %252e decodes to %2e on first pass. We decode once and check.
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "%2e%2e/etc/passwd", root: root)
        }
    }

    @Test("Mixed traversal with valid prefix is rejected")
    func mixedTraversal() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "notes/projects/../../..", root: root)
        }
    }
}

// MARK: - Symlink Attacks

@Suite("PathValidator — Symlink Attacks")
struct PathValidatorSymlinkTests {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    }

    @Test("Symlink pointing outside vault is rejected")
    func symlinkEscape() throws {
        let fm = FileManager.default
        let symlinkPath = root + "/notes/evil-link"

        // Create a symlink inside the vault that points to /tmp
        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: "/tmp")

        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "notes/evil-link", root: root)
        }
    }

    @Test("Symlink pointing within vault is allowed")
    func symlinkWithinVault() throws {
        let fm = FileManager.default
        // Create target
        try fm.createDirectory(atPath: root + "/notes/real-dir", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/notes/real-dir/note.md", contents: nil)

        // Create symlink within vault
        let symlinkPath = root + "/notes/link-to-real"
        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: root + "/notes/real-dir")

        let resolved = try PathValidator.resolve(relativePath: "notes/link-to-real/note.md", root: root)
        #expect(resolved.hasPrefix(root))
    }
}

// MARK: - Edge Cases

@Suite("PathValidator — Edge Cases")
struct PathValidatorEdgeCaseTests {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    }

    @Test("Empty path is rejected")
    func emptyPath() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "", root: root)
        }
    }

    @Test("Absolute path is rejected")
    func absolutePath() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(relativePath: "/etc/passwd", root: root)
        }
    }

    @Test("Disallowed extension is rejected")
    func disallowedExtension() {
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(
                relativePath: "notes/secrets.env",
                root: root,
                allowedExtensions: ["md", "markdown"]
            )
        }
    }

    @Test("Path with double slashes resolves safely")
    func doubleSlashes() throws {
        FileManager.default.createFile(atPath: root + "/notes/test.md", contents: nil)
        let resolved = try PathValidator.resolve(relativePath: "notes//test.md", root: root)
        #expect(resolved.hasPrefix(root))
    }

    @Test("Path with trailing slash resolves safely")
    func trailingSlash() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/", root: root)
        #expect(resolved.hasPrefix(root))
    }

    @Test("Root prefix attack is prevented (vault-evil vs vault)")
    func rootPrefixAttack() throws {
        let fm = FileManager.default
        // Create a sibling directory that shares the root prefix
        let evilRoot = root + "-evil"
        try fm.createDirectory(atPath: evilRoot, withIntermediateDirectories: true)
        fm.createFile(atPath: evilRoot + "/stolen.md", contents: nil)

        // Attempt to access sibling via traversal — this must fail
        #expect(throws: PathValidator.PathError.self) {
            try PathValidator.resolve(
                relativePath: "../" + (root as NSString).lastPathComponent + "-evil/stolen.md",
                root: root
            )
        }
    }

    @Test("Path with spaces resolves correctly")
    func pathWithSpaces() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes/my folder", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/notes/my folder/my note.md", contents: nil)

        let resolved = try PathValidator.resolve(relativePath: "notes/my folder/my note.md", root: root)
        #expect(resolved.contains("my folder"))
        #expect(resolved.hasPrefix(root))
    }

    @Test("Case sensitivity is preserved")
    func caseSensitivity() throws {
        let fm = FileManager.default
        fm.createFile(atPath: root + "/notes/README.md", contents: nil)

        let resolved = try PathValidator.resolve(relativePath: "notes/README.md", root: root)
        #expect(resolved.hasSuffix("/notes/README.md"))
    }

    @Test("Single dot path component is handled")
    func singleDotPath() throws {
        FileManager.default.createFile(atPath: root + "/notes/test.md", contents: nil)
        let resolved = try PathValidator.resolve(relativePath: "./notes/test.md", root: root)
        #expect(resolved.hasPrefix(root))
        #expect(resolved.hasSuffix("/notes/test.md"))
    }
}
