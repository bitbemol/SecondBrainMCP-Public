# SecondBrainMCP

A local MCP server in Swift that gives Claude Desktop read/write access to a Markdown note vault and read-only access to a PDF reference library. Every note edit is automatically committed to git.

```
Claude Desktop ─┐
                ├──stdio──> SecondBrainMCP
Claude Code CLI ─┘                |
                                  +── notes/       (Markdown, read/write, git tracked)
                                  +── references/  (PDFs, read-only)
```

> **Important:** MCP servers only work with **Claude Desktop** (the macOS app) and **Claude Code** (the CLI). They do **not** work with claude.ai in the browser.

## Features

- **14 MCP tools** — search, read, create, update, delete notes; search and read PDFs; git history and revert
- **4 MCP resources** — vault index, recent notes, tags summary, references index
- **Git auto-commit** — every write creates a commit with `[SecondBrainMCP]` prefix
- **Soft deletes** — deleted notes move to `.trash/`, never permanently removed
- **Full-text search** — TF-IDF scoring across notes and PDFs with title boost
- **PDF text extraction** — per-page caching, page/range/query modes
- **Read-only mode** — `--read-only` flag hides all write tools
- **Path security** — symlink resolution, traversal prevention, extension allowlists
- **Audit log** — every operation logged to `.secondbrain-mcp/audit.log`
- **Works alongside Obsidian, iA Writer, Logseq** — the vault is plain Markdown; app config directories are ignored
- **Custom instructions** — drop an `INSTRUCTIONS.md` in your vault root to define your own conventions

## Quick Start

```bash
# 1. Build
swift build -c release
# Binary is at .build/release/second-brain-mcp

# 2. Create a vault
./setup-vault.sh

# 3. Connect to Claude Desktop or Claude Code (see below)

# 4. Ask Claude: "What notes do I have?"
```

## Requirements

- Swift 6.2
- macOS 26 (Tahoe)
- Xcode 26

## Installation

```bash
git clone https://github.com/yourusername/SecondBrainMCP.git
cd SecondBrainMCP
swift build -c release
```

The binary is at `.build/release/second-brain-mcp`. You can copy it anywhere:

```bash
cp .build/release/second-brain-mcp /usr/local/bin/
```

## Connecting to Claude

SecondBrainMCP works with **Claude Desktop** (the macOS app) and **Claude Code** (the CLI). It does **not** work with claude.ai in the browser.

### Option A: Claude Desktop (the macOS app)

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "second-brain": {
      "command": "/absolute/path/to/.build/release/second-brain-mcp",
      "args": ["--vault", "/absolute/path/to/your/vault"]
    }
  }
}
```

**Restart Claude Desktop after saving** (Cmd+Q, then reopen). The server starts automatically when Claude needs it. Verify by asking Claude *"What tools do you have?"* — you should see the SecondBrainMCP tools.

### Option B: Claude Code (the CLI)

```bash
claude mcp add second-brain -- \
  /absolute/path/to/.build/release/second-brain-mcp \
  --vault /absolute/path/to/your/vault
```

This registers the server globally. It's available immediately in new `claude` sessions — no restart needed.

To scope it to a specific project instead, use `-s project`:

```bash
claude mcp add -s project second-brain -- \
  /absolute/path/to/.build/release/second-brain-mcp \
  --vault /absolute/path/to/your/vault
```

You can also import your Claude Desktop config directly:

```bash
claude mcp add-from-claude-desktop
```

Verify with:
```bash
claude mcp list
```

### What does NOT work

- **claude.ai** (the website) — does not support MCP servers
- **Claude mobile apps** — do not support MCP servers
- Any Claude interface that isn't Claude Desktop or Claude Code

## Vault Structure

```
~/SecondBrain/
├── notes/              <- Your Markdown notes (editable, git tracked)
│   ├── projects/
│   ├── journal/
│   └── ideas/
├── references/         <- PDF books and papers (read-only)
├── INSTRUCTIONS.md     <- Optional: custom rules for the AI (see below)
├── .git/               <- Auto-created on first run
├── .trash/             <- Soft-deleted notes land here
└── .secondbrain-mcp/   <- Audit log + PDF text cache
```

Only `notes/` and `references/` need to exist. Everything else is auto-created on first startup.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--vault <path>` | *(required)* | Path to your vault directory |
| `--read-only` | `false` | Disable all write/delete/revert tools |
| `--extensions <list>` | `md,markdown` | Allowed note file extensions |
| `--log-level <level>` | `info` | `debug`, `info`, `warning`, `error` |

## Tools

### Notes

| Tool | Description |
|------|-------------|
| `read_note` | Read a note's full content |
| `list_notes` | List notes, filter by directory or tag |
| `get_note_metadata` | Title, tags, word count, links |
| `search_notes` | Full-text search with TF-IDF ranking |
| `create_note` | Create with auto-generated frontmatter |
| `update_note` | Replace or append mode |
| `delete_note` | Soft-delete to `.trash/` |

### References (read-only)

| Tool | Description |
|------|-------------|
| `list_references` | List all PDFs with metadata |
| `read_reference` | Extract text by page, range, or query |
| `search_references` | Full-text search across all PDFs |
| `get_reference_metadata` | PDF metadata without reading content |

### Git History

| Tool | Description |
|------|-------------|
| `note_history` | Commit history for a specific note |
| `revert_note` | Revert to a previous version (new commit) |
| `vault_changelog` | Recent changes across the vault |

## Resources

| URI | Description |
|-----|-------------|
| `secondbrain://index` | All notes: paths, titles, tags |
| `secondbrain://recent` | Notes modified in the last 7 days |
| `secondbrain://tags` | All tags with note counts |
| `secondbrain://references` | All PDFs with metadata |

## Custom Instructions

Drop an `INSTRUCTIONS.md` file in your vault root to define conventions the AI should follow when managing your notes. For example:

```markdown
VAULT RULES:
1. Always create notes inside a container directory — never as loose files.
2. Every note must have YAML frontmatter with title, created date, and tags.
3. Ticket notes should start with the ticket ID.
```

The server appends the file contents to its default instructions during startup. If the file doesn't exist, only the built-in defaults are sent. No rebuild required — just create or edit the file and restart the MCP server.

## Security

- **Path traversal prevention** — all paths validated through `PathValidator` with symlink resolution
- **No arbitrary shell execution** — only `/usr/bin/git` with programmatic argument arrays
- **Structural write boundaries** — `ReferenceManager` has zero write methods by design
- **Soft deletes only** — files are never permanently deleted
- **Commit message sanitization** — shell metacharacters stripped from git messages

## Documentation

| File | Description |
|------|-------------|
| [USAGE-GUIDE.md](USAGE-GUIDE.md) | Full usage guide, tool reference, third-party app compatibility |
| [BUILD-GUIDE.md](BUILD-GUIDE.md) | Phase-by-phase build journal with design decisions |
| [SETUP-SCRIPT.md](SETUP-SCRIPT.md) | Setup script docs and machine transfer guide |
| [SecondBrainMCP-Spec.md](SecondBrainMCP-Spec.md) | Project specification (source of truth) |

## Architecture

```
Sources/SecondBrainMCP/
├── main.swift                    # Entry point
├── Config/ServerConfig.swift     # CLI args -> config
├── Server/MCPServerSetup.swift   # Server init, all handlers
├── Core/
│   ├── PathValidator.swift       # Path security (struct, static)
│   ├── VaultManager.swift        # Note I/O (actor)
│   ├── ReferenceManager.swift    # PDF ops, zero write methods (actor)
│   ├── SearchEngine.swift        # TF-IDF full-text index (actor)
│   ├── GitManager.swift          # Git via /usr/bin/git (actor)
│   ├── MarkdownParser.swift      # YAML frontmatter (struct, static)
│   ├── PDFTextExtractor.swift    # PDFKit wrapper (struct, static)
│   └── ReferenceCache.swift      # Per-page text cache (actor)
└── Logging/AuditLogger.swift     # Operation log (actor)
```

**Concurrency model:** Actors for mutable state (file I/O, search index, git), structs with static methods for stateless logic (path validation, PDF extraction, Markdown parsing). Swift 6.2 strict concurrency — no data races by construction.

## Tests

```bash
swift test                            # Run all 70 tests
swift test --filter PathValidatorTests # Run specific suite
```

| Suite | Tests | What it covers |
|-------|-------|----------------|
| PathValidator (4 suites) | 24 | Traversal attacks, symlinks, edge cases |
| GitManager | 8 | Init, commit, log, sanitization |
| MarkdownParser (4 suites) | 16 | Frontmatter, links, generation |
| VaultManager | 10 | Read, list, filter, metadata |
| SearchEngine | 12 | TF-IDF, ranking, incremental updates |

## License

MIT
