#!/bin/bash
#
# SecondBrainMCP — Vault Setup Script
# Creates the vault directory structure for use with SecondBrainMCP.
#

set -e

# Colors for output
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RESET='\033[0m'

echo ""
echo -e "${BOLD}SecondBrainMCP — Vault Setup${RESET}"
echo "─────────────────────────────"
echo ""

# Ask for vault name
read -p "Vault name (e.g. SecondBrain): " VAULT_NAME

if [ -z "$VAULT_NAME" ]; then
    echo "Error: vault name is required."
    exit 1
fi

# Ask for location (optional, defaults to current directory)
read -p "Location [$(pwd)]: " VAULT_LOCATION

if [ -z "$VAULT_LOCATION" ]; then
    VAULT_LOCATION="$(pwd)"
else
    # Expand ~ if used
    VAULT_LOCATION="${VAULT_LOCATION/#\~/$HOME}"
fi

VAULT_PATH="$VAULT_LOCATION/$VAULT_NAME"

# Check if it already exists
if [ -d "$VAULT_PATH" ]; then
    echo ""
    echo -e "${YELLOW}Warning:${RESET} $VAULT_PATH already exists."
    read -p "Continue and create missing directories? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Create directory structure
echo ""
echo -e "${CYAN}Creating vault structure...${RESET}"

mkdir -p "$VAULT_PATH/notes"
mkdir -p "$VAULT_PATH/references"

echo "  ✓ $VAULT_PATH/notes/"
echo "  ✓ $VAULT_PATH/references/"

# Create a welcome note
WELCOME_FILE="$VAULT_PATH/notes/welcome.md"
if [ ! -f "$WELCOME_FILE" ]; then
    cat > "$WELCOME_FILE" << 'EOF'
---
title: Welcome to your Second Brain
tags: [getting-started]
created: $(date +%Y-%m-%d)
---

# Welcome to your Second Brain

This vault is managed by **SecondBrainMCP**. Here's how it works:

## Structure

- `notes/` — Your Markdown notes. Organize with subdirectories however you like.
- `references/` — Drop PDF books and papers here. Read-only, never modified.

## Tips

- Notes support YAML frontmatter for titles and tags
- Every edit is automatically committed to git
- Deleted notes go to `.trash/` — nothing is permanently lost
- Use tags to organize: `tags: [project, swift, idea]`

Happy thinking!
EOF
    echo "  ✓ $VAULT_PATH/notes/welcome.md (starter note)"
fi

# Create a sample INSTRUCTIONS.md
INSTRUCTIONS_FILE="$VAULT_PATH/INSTRUCTIONS.md"
if [ ! -f "$INSTRUCTIONS_FILE" ]; then
    cat > "$INSTRUCTIONS_FILE" << 'EOF'
# Custom Instructions

> **Note:** The MCP server reads this file on startup. If you edit it mid-session,
> restart the MCP server (or restart your AI client) for changes to take effect.

> **⚠️ Compatibility:** Some AI clients don't automatically follow MCP-provided
> instructions. For example, Kiro requires you to copy these rules into its own
> steering files (`.kiro/steering/`) for them to take effect. If your client has
> a native configuration system for AI instructions, duplicate these rules there
> to ensure they're respected.

Add your vault conventions here. These are sent to the AI on every connection.
For example:

- Folder structure rules
- Naming conventions
- Tagging strategy
- Note templates

Delete this placeholder text and write your own rules, or remove this file
to use only the built-in defaults.
EOF
    echo "  ✓ $VAULT_PATH/INSTRUCTIONS.md (customize your rules)"
fi

# Done
echo ""
echo -e "${GREEN}${BOLD}Vault created!${RESET}"
echo ""
echo -e "  Path: ${BOLD}$VAULT_PATH${RESET}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Drop some PDFs into $VAULT_PATH/references/"
echo ""
echo "  2. Add to Claude Desktop config (~/.config/Claude/claude_desktop_config.json):"
echo ""
echo "     {"
echo "       \"mcpServers\": {"
echo "         \"second-brain\": {"
echo "           \"command\": \"$(cd "$(dirname "$0")" && pwd)/.build/release/second-brain-mcp\","
echo "           \"args\": [\"--vault\", \"$VAULT_PATH\"]"
echo "         }"
echo "       }"
echo "     }"
echo ""
echo "  3. Restart Claude Desktop"
echo ""
echo "  4. (Optional) Edit $VAULT_PATH/INSTRUCTIONS.md to define your vault conventions"
echo ""
