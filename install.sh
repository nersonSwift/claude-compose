#!/usr/bin/env bash
set -euo pipefail

# claude-compose installer
# Usage: curl -fsSL https://raw.githubusercontent.com/nersonSwift/claude-compose/main/install.sh | bash

REPO="nersonSwift/claude-compose"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_NAME="claude-compose"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Installing claude-compose...${NC}"

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo -e "${RED}Error: jq is required.${NC}"
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "  Install: brew install jq"
    else
        echo "  Install: sudo apt install jq"
    fi
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo -e "${RED}Warning: claude CLI not found. Install it before using claude-compose.${NC}"
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download
if command -v curl &>/dev/null; then
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/claude-compose" -o "${INSTALL_DIR}/${BINARY_NAME}"
elif command -v wget &>/dev/null; then
    wget -qO "${INSTALL_DIR}/${BINARY_NAME}" "https://raw.githubusercontent.com/${REPO}/main/claude-compose"
else
    echo -e "${RED}Error: curl or wget required.${NC}"
    exit 1
fi

chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

# Check PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo ""
    echo -e "${RED}${INSTALL_DIR} is not in your PATH.${NC}"
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        zsh)  RC_FILE="~/.zshrc" ;;
        bash) RC_FILE="~/.bashrc" ;;
        *)    RC_FILE="your shell rc file" ;;
    esac
    echo "Add this to ${RC_FILE}:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo ""
fi

echo -e "${GREEN}Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}${NC}"
echo ""
echo "Usage:"
echo "  claude-compose --help"
